// SPDX-License-Identifier: MIT

#include "terminalpolicy.h"

#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <fstream>
#include <limits>
#include <memory>
#include <sstream>
#include <string>
#include <string_view>
#include <unordered_map>
#include <utility>
#include <vector>

#include <fcitx-utils/capabilityflags.h>
#include <fcitx-utils/handlertable.h>
#include <fcitx-utils/key.h>
#include <fcitx-utils/keysym.h>
#include <fcitx/addonfactory.h>
#include <fcitx/addoninstance.h>
#include <fcitx/addonmanager.h>
#include <fcitx/candidatelist.h>
#include <fcitx/event.h>
#include <fcitx/inputcontext.h>
#include <fcitx/inputpanel.h>
#include <fcitx/instance.h>
#include <fcitx/text.h>
#include <fcitx/userinterface.h>

namespace fcitx {

namespace {

constexpr int kResultLimit = 40;
constexpr int kPageSize = 6;
constexpr size_t kMaxQueryLength = 48;

std::string normalize(std::string_view input) {
    std::string output;
    output.reserve(input.size());
    bool separator = false;

    for (unsigned char ch : input) {
        if (std::isalnum(ch) || ch == '+' || ch == '-') {
            if (separator && !output.empty()) {
                output.push_back('_');
            }
            output.push_back(static_cast<char>(std::tolower(ch)));
            separator = false;
        } else if (ch == '_' || std::isspace(ch)) {
            separator = true;
        }
    }

    if (!output.empty() && output.back() == '_') {
        output.pop_back();
    }
    return output;
}

std::vector<std::string> split(std::string_view input, char delimiter) {
    std::vector<std::string> output;
    size_t start = 0;
    while (start <= input.size()) {
        const auto end = input.find(delimiter, start);
        const auto value = input.substr(
            start, end == std::string_view::npos ? input.size() - start
                                                  : end - start);
        if (!value.empty()) {
            output.emplace_back(value);
        }
        if (end == std::string_view::npos) {
            break;
        }
        start = end + 1;
    }
    return output;
}

int subsequencePenalty(std::string_view needle, std::string_view haystack) {
    size_t needleIndex = 0;
    int gaps = 0;
    int run = 0;
    int bestRun = 0;

    for (size_t i = 0; i < haystack.size() && needleIndex < needle.size(); ++i) {
        if (haystack[i] == needle[needleIndex]) {
            ++needleIndex;
            ++run;
            bestRun = std::max(bestRun, run);
        } else if (needleIndex > 0) {
            ++gaps;
            run = 0;
        }
    }

    if (needleIndex != needle.size()) {
        return -1;
    }
    return gaps + static_cast<int>(needle.size()) - bestRun;
}

int levenshteinDistance(std::string_view left, std::string_view right,
                        int cutoff) {
    if (std::abs(static_cast<int>(left.size()) - static_cast<int>(right.size())) >
        cutoff) {
        return cutoff + 1;
    }

    std::vector<int> previous(right.size() + 1);
    std::vector<int> current(right.size() + 1);
    for (size_t j = 0; j <= right.size(); ++j) {
        previous[j] = static_cast<int>(j);
    }

    for (size_t i = 1; i <= left.size(); ++i) {
        current[0] = static_cast<int>(i);
        int rowMinimum = current[0];
        for (size_t j = 1; j <= right.size(); ++j) {
            const int cost = left[i - 1] == right[j - 1] ? 0 : 1;
            current[j] = std::min({previous[j] + 1, current[j - 1] + 1,
                                   previous[j - 1] + cost});
            rowMinimum = std::min(rowMinimum, current[j]);
        }
        if (rowMinimum > cutoff) {
            return cutoff + 1;
        }
        previous.swap(current);
    }
    return previous[right.size()];
}

struct Emoji {
    std::string glyph;
    std::string primaryAlias;
    std::vector<std::string> aliases;
    std::string searchable;
};

struct Match {
    const Emoji *emoji = nullptr;
    int score = std::numeric_limits<int>::max();
};

int scoreField(std::string_view query, std::string_view field, int base) {
    if (field == query) {
        return base;
    }
    if (field.starts_with(query)) {
        return base + 10 + static_cast<int>(field.size() - query.size());
    }

    const auto contains = field.find(query);
    if (contains != std::string_view::npos) {
        return base + 40 + static_cast<int>(contains);
    }

    const auto subsequence = subsequencePenalty(query, field);
    if (subsequence >= 0) {
        return base + 80 + subsequence;
    }

    if (query.size() >= 3) {
        const int allowed = query.size() >= 6 ? 2 : 1;
        const int distance = levenshteinDistance(query, field, allowed);
        if (distance <= allowed) {
            return base + 130 + distance * 10;
        }
    }
    return std::numeric_limits<int>::max();
}

} // namespace

class QuickEmoji;

class EmojiCandidate final : public CandidateWord {
public:
    EmojiCandidate(QuickEmoji *owner, std::string glyph, std::string name);
    void select(InputContext *inputContext) const override;

private:
    QuickEmoji *owner_;
    std::string glyph_;
};

class QuickEmoji final : public AddonInstance {
public:
    explicit QuickEmoji(Instance *instance) : instance_(instance) {
        loadDatabase();

        handlers_.emplace_back(instance_->watchEvent(
            EventType::InputContextKeyEvent, EventWatcherPhase::PreInputMethod,
            [this](Event &event) { handleKey(static_cast<KeyEvent &>(event)); }));
        handlers_.emplace_back(instance_->watchEvent(
            EventType::InputContextReset, EventWatcherPhase::Default,
            [this](Event &event) {
                reset(static_cast<InputContextEvent &>(event).inputContext());
            }));
        handlers_.emplace_back(instance_->watchEvent(
            EventType::InputContextFocusOut, EventWatcherPhase::Default,
            [this](Event &event) {
                auto *inputContext =
                    static_cast<InputContextEvent &>(event).inputContext();
                auto found = states_.find(inputContext);
                if (found != states_.end() && found->second.active) {
                    inputContext->commitString(":" + found->second.query);
                }
                reset(inputContext);
            }));
        handlers_.emplace_back(instance_->watchEvent(
            EventType::InputContextDestroyed, EventWatcherPhase::Default,
            [this](Event &event) {
                states_.erase(
                    static_cast<InputContextEvent &>(event).inputContext());
            }));
    }

    void commit(InputContext *inputContext, const std::string &text) {
        inputContext->commitString(text);
        reset(inputContext);
    }

private:
    struct State {
        bool active = false;
        std::string query;
        std::vector<Match> matches;
        int selected = 0;
    };

    void loadDatabase() {
        const char *home = std::getenv("HOME");
        if (!home) {
            return;
        }

        std::ifstream file(std::string(home) +
                           "/.local/share/quick-emoji/emojis.tsv");
        std::string line;
        while (std::getline(file, line)) {
            std::vector<std::string> fields;
            size_t start = 0;
            while (fields.size() < 3) {
                const auto end = line.find('\t', start);
                if (end == std::string::npos) {
                    break;
                }
                fields.push_back(line.substr(start, end - start));
                start = end + 1;
            }
            fields.push_back(line.substr(start));
            if (fields.size() != 4 || fields[0].empty() || fields[1].empty()) {
                continue;
            }

            Emoji emoji;
            emoji.glyph = fields[0];
            emoji.primaryAlias = normalize(fields[1]);
            for (auto &alias : split(fields[2], ',')) {
                auto normalized = normalize(alias);
                if (!normalized.empty()) {
                    emoji.aliases.push_back(std::move(normalized));
                }
            }
            if (emoji.aliases.empty()) {
                emoji.aliases.push_back(emoji.primaryAlias);
            }
            emoji.searchable = normalize(fields[3]);
            emojis_.push_back(std::move(emoji));
        }
    }

    const Emoji *exactMatch(std::string_view query) const {
        const auto needle = normalize(query);
        for (const auto &emoji : emojis_) {
            for (const auto &alias : emoji.aliases) {
                if (alias == needle) {
                    return &emoji;
                }
            }
        }
        return nullptr;
    }

    std::vector<Match> search(std::string_view query) const {
        const auto needle = normalize(query);
        std::vector<Match> results;
        if (needle.empty()) {
            return results;
        }

        for (const auto &emoji : emojis_) {
            int best = std::numeric_limits<int>::max();
            for (const auto &alias : emoji.aliases) {
                best = std::min(best, scoreField(needle, alias, 0));
            }
            best = std::min(best, scoreField(needle, emoji.searchable, 180));
            if (best != std::numeric_limits<int>::max()) {
                results.push_back({&emoji, best});
            }
        }

        std::stable_sort(results.begin(), results.end(),
                         [](const Match &left, const Match &right) {
                             if (left.score != right.score) {
                                 return left.score < right.score;
                             }
                             return left.emoji->primaryAlias <
                                    right.emoji->primaryAlias;
                         });
        if (results.size() > kResultLimit) {
            results.resize(kResultLimit);
        }
        return results;
    }

    bool unavailable(InputContext *inputContext) const {
        const auto capabilities = inputContext->capabilityFlags();
        if (capabilities.test(CapabilityFlag::Password) ||
            capabilities.test(CapabilityFlag::Disable) || emojis_.empty()) {
            return true;
        }
        return quickemoji::terminalBlocked(inputContext->program());
    }

    static bool hasCommandModifier(const Key &key) {
        const auto states = key.states();
        return states.test(KeyState::Ctrl) || states.test(KeyState::Alt) ||
               states.test(KeyState::Super) || states.test(KeyState::Super2) ||
               states.test(KeyState::Hyper) || states.test(KeyState::Meta);
    }

    static char queryCharacter(const Key &key) {
        const auto symbol = key.sym();
        if ((symbol >= FcitxKey_a && symbol <= FcitxKey_z) ||
            (symbol >= FcitxKey_A && symbol <= FcitxKey_Z) ||
            (symbol >= FcitxKey_0 && symbol <= FcitxKey_9) ||
            symbol == FcitxKey_underscore || symbol == FcitxKey_minus ||
            symbol == FcitxKey_plus) {
            const auto unicode = Key::keySymToUnicode(symbol);
            if (unicode > 0 && unicode < 128) {
                return static_cast<char>(std::tolower(unicode));
            }
        }
        return '\0';
    }

    void handleKey(KeyEvent &event) {
        if (event.isRelease() || event.filtered()) {
            return;
        }

        auto *inputContext = event.inputContext();
        auto &state = states_[inputContext];
        const auto &key = event.key();

        if (!state.active) {
            if (!unavailable(inputContext) && key.sym() == FcitxKey_colon &&
                !hasCommandModifier(key)) {
                state = State{true, "", {}, 0};
                update(inputContext);
                event.filterAndAccept();
            }
            return;
        }

        if (key.sym() == FcitxKey_Escape) {
            commit(inputContext, ":" + state.query);
            event.filterAndAccept();
            return;
        }

        if (key.sym() == FcitxKey_BackSpace) {
            if (state.query.empty()) {
                reset(inputContext);
            } else {
                state.query.pop_back();
                state.selected = 0;
                update(inputContext);
            }
            event.filterAndAccept();
            return;
        }

        if (key.sym() == FcitxKey_colon && !hasCommandModifier(key)) {
            if (const auto *emoji = exactMatch(state.query)) {
                commit(inputContext, emoji->glyph);
            } else {
                commit(inputContext, ":" + state.query + ":");
            }
            event.filterAndAccept();
            return;
        }

        if (key.sym() == FcitxKey_Up || key.sym() == FcitxKey_KP_Up) {
            if (!state.matches.empty()) {
                state.selected =
                    (state.selected - 1 + static_cast<int>(state.matches.size())) %
                    static_cast<int>(state.matches.size());
                update(inputContext);
            }
            event.filterAndAccept();
            return;
        }

        if (key.sym() == FcitxKey_Down || key.sym() == FcitxKey_KP_Down) {
            if (!state.matches.empty()) {
                state.selected =
                    (state.selected + 1) % static_cast<int>(state.matches.size());
                update(inputContext);
            }
            event.filterAndAccept();
            return;
        }

        if (key.sym() == FcitxKey_Page_Up || key.sym() == FcitxKey_Page_Down) {
            if (!state.matches.empty()) {
                const int delta = key.sym() == FcitxKey_Page_Up ? -kPageSize
                                                                : kPageSize;
                state.selected = std::clamp(
                    state.selected + delta, 0,
                    static_cast<int>(state.matches.size()) - 1);
                update(inputContext);
            }
            event.filterAndAccept();
            return;
        }

        const bool choose = key.sym() == FcitxKey_Return ||
                            key.sym() == FcitxKey_KP_Enter ||
                            key.sym() == FcitxKey_space ||
                            key.sym() == FcitxKey_Tab;
        if (choose && !state.matches.empty()) {
            commit(inputContext,
                   state.matches[static_cast<size_t>(state.selected)].emoji->glyph);
            event.filterAndAccept();
            return;
        }

        if (!hasCommandModifier(key)) {
            const char character = queryCharacter(key);
            if (character != '\0' && state.query.size() < kMaxQueryLength) {
                state.query.push_back(character);
                state.selected = 0;
                update(inputContext);
                event.filterAndAccept();
                return;
            }
        }

        const auto raw = ":" + state.query;
        reset(inputContext);
        inputContext->commitString(raw);
        // Leave this event unfiltered so punctuation, shortcuts, and Enter keep
        // their normal meaning after the literal text has been restored.
    }

    void update(InputContext *inputContext) {
        auto found = states_.find(inputContext);
        if (found == states_.end() || !found->second.active) {
            return;
        }
        auto &state = found->second;
        state.matches = search(state.query);
        if (state.matches.empty()) {
            state.selected = 0;
        } else {
            state.selected = std::clamp(
                state.selected, 0, static_cast<int>(state.matches.size()) - 1);
        }

        auto &panel = inputContext->inputPanel();
        panel.reset();

        Text preedit;
        preedit.append(":" + state.query, TextFormatFlag::Underline);
        preedit.setCursor(state.query.size() + 1);
        if (inputContext->capabilityFlags().test(CapabilityFlag::Preedit)) {
            panel.setClientPreedit(preedit);
        } else {
            panel.setPreedit(preedit);
        }

        if (!state.query.empty()) {
            panel.setAuxUp(Text(state.query));
            auto candidates = std::make_unique<CommonCandidateList>();
            candidates->setPageSize(kPageSize);
            candidates->setLayoutHint(CandidateLayoutHint::Vertical);
            candidates->setLabels({});
            // Render a sliding six-row window instead of Fcitx pages. Arrow
            // navigation then advances one result at a time, including across
            // the old page boundary, while explicit Page Up/Down still moves
            // the selection by kPageSize.
            const int windowStart = std::max(0, state.selected - kPageSize + 1);
            const int windowEnd = std::min(
                windowStart + kPageSize,
                static_cast<int>(state.matches.size()));
            for (int index = windowStart; index < windowEnd; ++index) {
                const auto &match = state.matches[static_cast<size_t>(index)];
                candidates->append<EmojiCandidate>(
                    this, match.emoji->glyph, match.emoji->primaryAlias);
            }
            if (!state.matches.empty()) {
                candidates->setCursorIndex(state.selected - windowStart);
            }
            panel.setCandidateList(std::move(candidates));
        }

        inputContext->updatePreedit();
        inputContext->updateUserInterface(UserInterfaceComponent::InputPanel);
    }

    void reset(InputContext *inputContext) {
        auto found = states_.find(inputContext);
        if (found != states_.end()) {
            found->second = State{};
        }
        inputContext->inputPanel().reset();
        inputContext->updatePreedit();
        inputContext->updateUserInterface(UserInterfaceComponent::InputPanel);
    }

    Instance *instance_;
    std::vector<Emoji> emojis_;
    std::unordered_map<InputContext *, State> states_;
    std::vector<std::unique_ptr<HandlerTableEntry<EventHandler>>> handlers_;
};

EmojiCandidate::EmojiCandidate(QuickEmoji *owner, std::string glyph,
                               std::string name)
    : CandidateWord(Text(glyph)), owner_(owner), glyph_(std::move(glyph)) {
    setComment(Text(std::move(name)));
}

void EmojiCandidate::select(InputContext *inputContext) const {
    owner_->commit(inputContext, glyph_);
}

class QuickEmojiFactory final : public AddonFactory {
public:
    AddonInstance *create(AddonManager *manager) override {
        return new QuickEmoji(manager->instance());
    }
};

} // namespace fcitx

FCITX_ADDON_FACTORY_V2(quickemoji, fcitx::QuickEmojiFactory)

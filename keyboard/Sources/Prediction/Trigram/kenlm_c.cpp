#include "kenlm_c.h"

// KenLM includes — paths relative to third-party/kenlm/kenlm-source/
#include "kenlm-source/lm/model.hh"
#include "kenlm-source/util/string_piece.hh"

#include <cstring>
#include <string>
#include <vector>
#include <sstream>
#include <cstdint>

// ---------------------------------------------------------------------------
// Internal: wrapper struct to hold the model instance and catch exceptions
// at the C++ → C boundary.
// ---------------------------------------------------------------------------

struct KenlmModel {
    // Use the concrete QuantArrayTrieModel type for our quantized + array-compressed
    // models.  This gives us direct access to the concrete Vocabulary and its Bound().
    lm::ngram::QuantArrayTrieModel* model;

    explicit KenlmModel(const char* path) : model(nullptr) {
        try {
            lm::ngram::Config config;
            // Suppress progress output for keyboard use.
            config.show_progress = false;
            config.messages = nullptr;
            model = new lm::ngram::QuantArrayTrieModel(path, config);
        } catch (const std::exception&) {
            delete model;
            model = nullptr;
        }
    }

    ~KenlmModel() {
        delete model;
        model = nullptr;
    }

    KenlmModel(const KenlmModel&) = delete;
    KenlmModel& operator=(const KenlmModel&) = delete;
};

// ---------------------------------------------------------------------------
// Helper: score a word sequence using QuantArrayTrieModel's typed API.
// ---------------------------------------------------------------------------

static double score_words(const KenlmModel* wrapper, const std::vector<const char*>& words) {
    if (!wrapper || !wrapper->model || words.empty()) return 0.0;

    try {
        const lm::ngram::QuantArrayTrieModel* model = wrapper->model;
        const lm::ngram::SortedVocabulary& vocab = model->GetVocabulary();
        lm::ngram::State state = model->BeginSentenceState();
        lm::ngram::State out_state;

        float total_log10 = 0.0f;

        for (const char* w : words) {
            if (!w || w[0] == '\0') continue;

            lm::WordIndex idx = vocab.Index(StringPiece(w));

            // FullScore returns log10 probability and advances state.
            lm::FullScoreReturn ret = model->FullScore(state, idx, out_state);
            total_log10 += ret.prob;

            state = out_state;
        }

        return static_cast<double>(total_log10);
    } catch (const std::exception&) {
        return 0.0;
    }
}

// ---------------------------------------------------------------------------
// C API implementation
// ---------------------------------------------------------------------------

kenlm_model_t kenlm_load(const char* path) {
    if (!path || path[0] == '\0') return nullptr;

    KenlmModel* wrapper = new (std::nothrow) KenlmModel(path);
    if (!wrapper || !wrapper->model) {
        delete wrapper;
        return nullptr;
    }
    return static_cast<void*>(wrapper);
}

void kenlm_free(kenlm_model_t model) {
    if (!model) return;
    delete static_cast<KenlmModel*>(model);
}

double kenlm_score(kenlm_model_t model, const char* const* words) {
    if (!model || !words) return 0.0;

    KenlmModel* wrapper = static_cast<KenlmModel*>(model);

    // Build vector from NULL-terminated C string array.
    std::vector<const char*> vec;
    for (const char* const* p = words; *p != nullptr; ++p) {
        vec.push_back(*p);
    }

    return score_words(wrapper, vec);
}

double kenlm_score_sentence(kenlm_model_t model, const char* sentence) {
    if (!model || !sentence || sentence[0] == '\0') return 0.0;

    KenlmModel* wrapper = static_cast<KenlmModel*>(model);

    // Tokenize on whitespace via istringstream.
    std::istringstream stream(sentence);
    std::string token;
    std::vector<std::string> storage;
    while (stream >> token) {
        storage.push_back(std::move(token));
    }
    if (storage.empty()) return 0.0;

    std::vector<const char*> words;
    words.reserve(storage.size());
    for (const auto& s : storage) {
        words.push_back(s.c_str());
    }

    return score_words(wrapper, words);
}

int kenlm_vocab_size(kenlm_model_t model) {
    if (!model) return 0;
    KenlmModel* wrapper = static_cast<KenlmModel*>(model);
    if (!wrapper->model) return 0;
    return static_cast<int>(wrapper->model->GetVocabulary().Bound());
}

const char* kenlm_version(void) {
    return "KenLM 4cb443e (query-only subset)";
}

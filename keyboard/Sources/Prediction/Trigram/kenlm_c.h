#ifndef KENLM_C_H
#define KENLM_C_H

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque handle to a loaded KenLM model. */
typedef void* kenlm_model_t;

/* Load a trie model from a binary file path. Returns NULL on failure. */
kenlm_model_t kenlm_load(const char* path);

/* Free a previously-loaded model. Safe to call with NULL. */
void kenlm_free(kenlm_model_t model);

/* Returns log10 probability of `words` (NULL-terminated array of C strings)
   under the model. Returns 0.0 if model is NULL or words is NULL/empty. */
double kenlm_score(kenlm_model_t model, const char* const* words);

/* One-shot: returns log10 probability of a single space-separated sentence.
   Returns 0.0 if model is NULL or sentence is NULL. */
double kenlm_score_sentence(kenlm_model_t model, const char* sentence);

/* Returns the vocabulary size of the loaded model. Returns 0 if model is NULL. */
int kenlm_vocab_size(kenlm_model_t model);

/* Returns the KenLM version string (static, do not free). */
const char* kenlm_version(void);

#ifdef __cplusplus
}
#endif

#endif /* KENLM_C_H */

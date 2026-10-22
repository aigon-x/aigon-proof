//! Local neural embeddings (ONNX via fastembed). No network at query time once the model is
//! cached; if the model cannot be loaded the caller falls back to lexical vectors and says so.

use std::sync::{Mutex, OnceLock};

use fastembed::{EmbeddingModel, TextEmbedding, TextInitOptions};

static MODEL: OnceLock<Option<Mutex<TextEmbedding>>> = OnceLock::new();

fn disabled() -> bool {
    std::env::var("AIGON_EMBEDDINGS").as_deref() == Ok("0")
}

pub fn model() -> Option<&'static Mutex<TextEmbedding>> {
    if disabled() {
        return None;
    }
    MODEL
        .get_or_init(|| {
            let cache = std::env::var("AIGON_EMBEDDING_CACHE")
                .unwrap_or_else(|_| "/var/tmp/aigon-embeddings".into());
            let options = TextInitOptions::new(EmbeddingModel::MultilingualE5Small)
                .with_cache_dir(cache.into())
                .with_show_download_progress(false);
            match TextEmbedding::try_new(options) {
                Ok(model) => Some(Mutex::new(model)),
                Err(err) => {
                    tracing::warn!(error = %err, "embedding model unavailable; lexical fallback");
                    None
                }
            }
        })
        .as_ref()
}

pub fn embed(texts: Vec<String>) -> Option<Vec<Vec<f32>>> {
    let model = model()?;
    let mut guard = model.lock().ok()?;
    guard.embed(texts, None).ok()
}

pub fn cosine(a: &[f32], b: &[f32]) -> f32 {
    let dot: f32 = a.iter().zip(b).map(|(x, y)| x * y).sum();
    let na: f32 = a.iter().map(|x| x * x).sum::<f32>().sqrt();
    let nb: f32 = b.iter().map(|x| x * x).sum::<f32>().sqrt();
    if na == 0.0 || nb == 0.0 {
        0.0
    } else {
        dot / (na * nb)
    }
}

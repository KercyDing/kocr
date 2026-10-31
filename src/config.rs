use std::collections::BTreeMap;

#[derive(Debug)]
pub(crate) struct ModelIndex {
    pub(crate) profiles: BTreeMap<String, ModelProfile>,
}

#[derive(Debug, Clone, Copy)]
pub(crate) struct ModelProfile {
    pub(crate) id: u32,
    pub(crate) url: &'static str,
    pub(crate) sha256: &'static str,
}

// Built-in model catalog. Models change rarely, so keep it compiled in.
const MODEL_PROFILES: &[(&str, ModelProfile)] = &[
    (
        "ppocrv6-small-int8-r1",
        ModelProfile {
            id: 1,
            url: "https://github.com/byrizki/rusto-rs/releases/download/models-rten-v0.3.2/RustO-Models-PPOCRv6-Small-INT8.zip",
            sha256: "ebceccf1a145c46dd8e948670c48b5c9055056788bce779dec4117cc0e06c50a",
        },
    ),
    (
        "ppocrv6-medium-int8-r1",
        ModelProfile {
            id: 2,
            url: "https://github.com/byrizki/rusto-rs/releases/download/models-rten-v0.3.2/RustO-Models-PPOCRv6-Medium-INT8.zip",
            sha256: "3e3a88b577bd7e85c5ee24e3e2a9866c7d3a98b1f58b3940ddd46dfb582c2a3d",
        },
    ),
    (
        "ppocrv6-tiny-int8-r1",
        ModelProfile {
            id: 3,
            url: "https://github.com/byrizki/rusto-rs/releases/download/models-rten-v0.3.2/RustO-Models-PPOCRv6-Tiny-INT8.zip",
            sha256: "a058fe33c7ae28e352476d2ae6e81d262f90e882523a419ae829103ce60d0fce",
        },
    ),
];

pub(crate) fn profiles() -> BTreeMap<String, ModelProfile> {
    MODEL_PROFILES
        .iter()
        .map(|(name, profile)| ((*name).to_owned(), *profile))
        .collect()
}

//! Parameter dependency map for dirty-flag incremental mesh updates.
//!
//! Built once when a [`crate::runtime::ModelRuntime`] is constructed. Each
//! drawable and glue gets a bitset of the parameter indices that can affect it
//! (its own keyform band plus, for drawables, every band on the parent
//! deformer chain), so per-frame updates can skip entities whose bound
//! parameters did not change.

use super::{Moc3ArtMeshes, Moc3Deformers, Moc3Glues, Moc3KeyformBindings, Moc3Parts};

#[derive(Debug, Clone, Default)]
pub(crate) struct Moc3DependencyMap {
    words: usize,
    drawable_masks: Vec<u64>,
    glue_masks: Vec<u64>,
    /// Drawable index pair per glue; validated against the drawable count.
    glue_pairs: Vec<(usize, usize)>,
    /// Union of all part keyform bands; gates the group render order pass.
    parts_mask: Vec<u64>,
    /// Set when glue metadata is invalid; forces the full update path.
    always_full: bool,
}

impl Moc3DependencyMap {
    pub(crate) fn build(
        parameter_count: usize,
        art_meshes: &Moc3ArtMeshes,
        deformers: &Moc3Deformers,
        bindings: &Moc3KeyformBindings,
        glues: &Moc3Glues,
        parts: &Moc3Parts,
    ) -> Self {
        let words = parameter_count.div_ceil(64).max(1);
        let drawable_count = art_meshes.meshes().len();

        // Cumulative masks per deformer: own band plus the parent chain.
        // `depth_order` guarantees parents are processed before children.
        let deformer_count = deformers.deformer_count();
        let mut deformer_masks = vec![0u64; deformer_count * words];
        for &index in deformers.depth_order() {
            if let Some(band) = deformers.deformer_keyform_binding_band_index(index) {
                bindings.for_each_band_parameter_index(band, |parameter_index| {
                    set_bit(
                        &mut deformer_masks[index * words..(index + 1) * words],
                        parameter_index,
                    );
                });
            }
            let parent = deformers
                .parent_deformer_index(index)
                .and_then(|p| usize::try_from(p).ok());
            if let Some(parent) = parent.filter(|&p| p < deformer_count) {
                for word in 0..words {
                    let parent_word = deformer_masks[parent * words + word];
                    deformer_masks[index * words + word] |= parent_word;
                }
            }
        }

        let mut drawable_masks = vec![0u64; drawable_count * words];
        for drawable in 0..drawable_count {
            if let Some(band) = art_meshes.art_mesh_keyform_binding_band_index(drawable) {
                bindings.for_each_band_parameter_index(band, |parameter_index| {
                    set_bit(
                        &mut drawable_masks[drawable * words..(drawable + 1) * words],
                        parameter_index,
                    );
                });
            }
            let parent = art_meshes
                .art_mesh_parent_deformer_index(drawable)
                .and_then(|p| usize::try_from(p).ok());
            if let Some(parent) = parent.filter(|&p| p < deformer_count) {
                for word in 0..words {
                    let parent_word = deformer_masks[parent * words + word];
                    drawable_masks[drawable * words + word] |= parent_word;
                }
            }
        }

        let mut always_full = false;
        let glue_count = glues.len();
        let mut glue_masks = vec![0u64; glue_count * words];
        let mut glue_pairs = Vec::with_capacity(glue_count);
        for glue in 0..glue_count {
            if let Some(band) = glues.binding_band_index(glue) {
                bindings.for_each_band_parameter_index(band, |parameter_index| {
                    set_bit(
                        &mut glue_masks[glue * words..(glue + 1) * words],
                        parameter_index,
                    );
                });
            }
            match glues.art_mesh_pair(glue) {
                Some((a, b)) if a < drawable_count && b < drawable_count => {
                    glue_pairs.push((a, b));
                }
                _ => {
                    // Such a model cannot pass the initial update in
                    // `ModelRuntime::new`, but stay defensive: never take the
                    // incremental path with unusable glue metadata.
                    always_full = true;
                    glue_pairs.push((0, 0));
                }
            }
        }

        let mut parts_mask = vec![0u64; words];
        for part in 0..parts.part_count() {
            if let Some(band) = parts.keyform_binding_band_index(part) {
                bindings.for_each_band_parameter_index(band, |parameter_index| {
                    set_bit(&mut parts_mask, parameter_index);
                });
            }
        }

        Self {
            words,
            drawable_masks,
            glue_masks,
            glue_pairs,
            parts_mask,
            always_full,
        }
    }

    pub(crate) fn words(&self) -> usize {
        self.words
    }

    pub(crate) fn always_full(&self) -> bool {
        self.always_full
    }

    pub(crate) fn drawable_depends_on(&self, drawable: usize, dirty_params: &[u64]) -> bool {
        intersects(
            &self.drawable_masks[drawable * self.words..(drawable + 1) * self.words],
            dirty_params,
        )
    }

    pub(crate) fn glue_depends_on(&self, glue: usize, dirty_params: &[u64]) -> bool {
        intersects(
            &self.glue_masks[glue * self.words..(glue + 1) * self.words],
            dirty_params,
        )
    }

    pub(crate) fn glue_pair(&self, glue: usize) -> (usize, usize) {
        self.glue_pairs[glue]
    }

    pub(crate) fn parts_depend_on(&self, dirty_params: &[u64]) -> bool {
        intersects(&self.parts_mask, dirty_params)
    }
}

fn set_bit(mask: &mut [u64], bit: usize) {
    if let Some(word) = mask.get_mut(bit / 64) {
        *word |= 1u64 << (bit % 64);
    }
}

fn intersects(mask: &[u64], dirty: &[u64]) -> bool {
    mask.iter().zip(dirty).any(|(m, d)| m & d != 0)
}

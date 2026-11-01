use std::ops::Range;

use wgpu::util::DeviceExt;

use crate::moc3::{Moc3DrawableBlendMode, Moc3DrawableMesh};
use crate::render::common::{
    ClippingRect, DrawableInfo, DrawableVertex, draw_order_indices_from, encode_indices,
    encode_vertices_from_drawable, encode_vertices_into,
};

pub fn drawable_vertex_layout() -> wgpu::VertexBufferLayout<'static> {
    const ATTRIBUTES: [wgpu::VertexAttribute; 5] = [
        wgpu::VertexAttribute {
            format: wgpu::VertexFormat::Float32x2,
            offset: 0,
            shader_location: 0,
        },
        wgpu::VertexAttribute {
            format: wgpu::VertexFormat::Float32x2,
            offset: 8,
            shader_location: 1,
        },
        wgpu::VertexAttribute {
            format: wgpu::VertexFormat::Float32,
            offset: 16,
            shader_location: 2,
        },
        wgpu::VertexAttribute {
            format: wgpu::VertexFormat::Float32x3,
            offset: 20,
            shader_location: 3,
        },
        wgpu::VertexAttribute {
            format: wgpu::VertexFormat::Float32x3,
            offset: 32,
            shader_location: 4,
        },
    ];

    wgpu::VertexBufferLayout {
        array_stride: DrawableVertex::STRIDE as wgpu::BufferAddress,
        step_mode: wgpu::VertexStepMode::Vertex,
        attributes: &ATTRIBUTES,
    }
}

#[derive(Debug)]
pub struct WgpuDrawableBuffers {
    index_buffer: wgpu::Buffer,
    vertex_count: u32,
    index_count: u32,
    vertex_bytes: Vec<u8>,
    indices: Vec<u16>,
    info: DrawableInfo,
    vertex_offset: u64,
    vertex_len: u64,
}

impl WgpuDrawableBuffers {
    pub fn vertex_range(&self) -> Range<u64> {
        self.vertex_offset..self.vertex_offset + self.vertex_len
    }

    pub fn index_buffer(&self) -> &wgpu::Buffer {
        &self.index_buffer
    }

    pub fn index_count(&self) -> u32 {
        self.index_count
    }

    pub fn is_empty(&self) -> bool {
        self.vertex_count == 0 || self.index_count == 0
    }

    pub fn is_visible(&self) -> bool {
        !self.is_empty() && self.info.is_visible()
    }

    pub fn info(&self) -> &DrawableInfo {
        &self.info
    }

    pub fn texture_index(&self) -> i32 {
        self.info.texture_index()
    }

    pub fn blend_mode(&self) -> Moc3DrawableBlendMode {
        self.info.blend_mode()
    }

    pub fn opacity(&self) -> f32 {
        self.info.opacity()
    }

    pub fn draw_order(&self) -> f32 {
        self.info.draw_order()
    }

    pub fn render_order(&self) -> i32 {
        self.info.render_order()
    }

    pub fn masks(&self) -> &[i32] {
        self.info.masks()
    }

    pub fn inverted_mask(&self) -> bool {
        self.info.inverted_mask()
    }

    pub fn bounds(&self) -> Option<ClippingRect> {
        self.info.bounds()
    }
}

#[derive(Debug)]
pub struct WgpuMeshBuffers {
    drawables: Vec<WgpuDrawableBuffers>,
    draw_order_indices: Vec<usize>,
    shared_vertex_buffer: wgpu::Buffer,
    scratch: Vec<u8>,
}

#[derive(Debug, Copy, Clone, PartialEq, Eq)]
pub struct WgpuMeshUpdate {
    uploaded_drawables: usize,
    bounds_changed: bool,
    visibility_changed: bool,
}

impl WgpuMeshUpdate {
    pub fn uploaded_drawables(&self) -> usize {
        self.uploaded_drawables
    }

    pub fn bounds_changed(&self) -> bool {
        self.bounds_changed
    }

    pub fn visibility_changed(&self) -> bool {
        self.visibility_changed
    }
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum WgpuMeshUpdateError {
    #[error("drawable count changed from {expected} to {actual}")]
    DrawableCount { expected: usize, actual: usize },
    #[error("drawable {drawable_index} vertex count changed from {expected} to {actual}")]
    VertexCount {
        drawable_index: usize,
        expected: usize,
        actual: usize,
    },
    #[error("drawable {drawable_index} index count changed from {expected} to {actual}")]
    IndexCount {
        drawable_index: usize,
        expected: usize,
        actual: usize,
    },
    #[error("drawable {drawable_index} indices changed")]
    Indices { drawable_index: usize },
    #[error("drawable {drawable_index} texture index changed from {expected} to {actual}")]
    TextureIndex {
        drawable_index: usize,
        expected: i32,
        actual: i32,
    },
    #[error("drawable {drawable_index} blend mode changed from {expected:?} to {actual:?}")]
    BlendMode {
        drawable_index: usize,
        expected: Moc3DrawableBlendMode,
        actual: Moc3DrawableBlendMode,
    },
    #[error("drawable {drawable_index} masks changed")]
    Masks { drawable_index: usize },
    #[error("drawable {drawable_index} inverted mask changed from {expected} to {actual}")]
    InvertedMask {
        drawable_index: usize,
        expected: bool,
        actual: bool,
    },
}

impl WgpuMeshBuffers {
    pub fn from_drawables(device: &wgpu::Device, meshes: &[Moc3DrawableMesh]) -> Option<Self> {
        let total_bytes: usize = meshes
            .iter()
            .map(|m| m.vertices().len() * DrawableVertex::STRIDE)
            .sum();
        let mut scratch = vec![0u8; total_bytes];

        let mut drawables = Vec::with_capacity(meshes.len());
        let mut offset: u64 = 0;
        for mesh in meshes {
            let vertex_count = u32::try_from(mesh.vertices().len()).ok()?;
            let index_count = u32::try_from(mesh.indices().len()).ok()?;
            let byte_len = mesh.vertices().len() * DrawableVertex::STRIDE;

            let slot = &mut scratch[offset as usize..offset as usize + byte_len];
            encode_vertices_into(mesh, slot);

            let index_bytes = encode_indices(mesh.indices());
            let index_buffer = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
                label: Some("live2d.drawable.indices"),
                contents: &index_bytes,
                usage: wgpu::BufferUsages::INDEX,
            });

            drawables.push(WgpuDrawableBuffers {
                index_buffer,
                vertex_count,
                index_count,
                vertex_bytes: slot.to_vec(),
                indices: mesh.indices().to_vec(),
                info: DrawableInfo::from_mesh(mesh),
                vertex_offset: offset,
                vertex_len: byte_len as u64,
            });
            offset += byte_len as u64;
        }

        let shared_vertex_buffer = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("live2d.shared.vertices"),
            contents: &scratch,
            usage: wgpu::BufferUsages::VERTEX | wgpu::BufferUsages::COPY_DST,
        });

        let draw_order_indices = draw_order_indices_from(
            drawables.len(),
            |index| drawables[index].draw_order(),
            |index| drawables[index].render_order(),
        );

        Some(Self {
            drawables,
            draw_order_indices,
            shared_vertex_buffer,
            scratch,
        })
    }

    pub fn vertex_buffer(&self) -> &wgpu::Buffer {
        &self.shared_vertex_buffer
    }

    pub fn drawables(&self) -> &[WgpuDrawableBuffers] {
        &self.drawables
    }

    pub fn drawable_infos(&self) -> Vec<DrawableInfo> {
        self.drawables.iter().map(|d| d.info.clone()).collect()
    }

    pub(crate) fn iter_drawable_infos(&self) -> impl Iterator<Item = &DrawableInfo> {
        self.drawables.iter().map(WgpuDrawableBuffers::info)
    }

    pub(crate) fn drawable_bounds(&self, drawable_index: usize) -> Option<ClippingRect> {
        self.drawables
            .get(drawable_index)
            .and_then(WgpuDrawableBuffers::bounds)
    }

    pub fn draw_order_indices(&self) -> &[usize] {
        &self.draw_order_indices
    }

    pub fn update_drawables(
        &mut self,
        queue: &wgpu::Queue,
        meshes: &[Moc3DrawableMesh],
    ) -> Result<WgpuMeshUpdate, WgpuMeshUpdateError> {
        if self.drawables.len() != meshes.len() {
            return Err(WgpuMeshUpdateError::DrawableCount {
                expected: self.drawables.len(),
                actual: meshes.len(),
            });
        }

        for (drawable_index, (drawable, mesh)) in self.drawables.iter().zip(meshes).enumerate() {
            validate_drawable_update(drawable_index, drawable, mesh)?;
        }

        let mut tmp = Vec::new();
        let mut uploads = 0;
        let mut min_off: Option<u64> = None;
        let mut max_end: u64 = 0;
        let mut bounds_changed = false;
        let mut visibility_changed = false;
        let mut order_changed = false;

        for (drawable, mesh) in self.drawables.iter_mut().zip(meshes) {
            encode_vertices_from_drawable(mesh, &mut tmp);
            if tmp != drawable.vertex_bytes && !tmp.is_empty() {
                let off = drawable.vertex_offset as usize;
                let len = drawable.vertex_len as usize;
                self.scratch[off..off + len].copy_from_slice(&tmp);
                std::mem::swap(&mut drawable.vertex_bytes, &mut tmp);
                uploads += 1;
                let start = drawable.vertex_offset;
                let end = drawable.vertex_offset + drawable.vertex_len;
                min_off = Some(min_off.map_or(start, |m: u64| m.min(start)));
                max_end = max_end.max(end);
            }
            let was_visible = drawable.is_visible();
            order_changed |= drawable.draw_order() != mesh.draw_order()
                || drawable.render_order() != mesh.render_order();
            let old_bounds = drawable.info.bounds();
            drawable.info.update_dynamic_from_mesh(mesh);
            let is_visible = !drawable.is_empty() && drawable.info.is_visible();
            bounds_changed |= old_bounds != drawable.info.bounds();
            visibility_changed |= was_visible != is_visible;
        }

        if let Some(start) = min_off {
            queue.write_buffer(
                &self.shared_vertex_buffer,
                start,
                &self.scratch[start as usize..max_end as usize],
            );
        }

        if order_changed {
            self.draw_order_indices = draw_order_indices_from(
                self.drawables.len(),
                |index| self.drawables[index].draw_order(),
                |index| self.drawables[index].render_order(),
            );
        }

        Ok(WgpuMeshUpdate {
            uploaded_drawables: uploads,
            bounds_changed,
            visibility_changed,
        })
    }
}

fn validate_drawable_update(
    drawable_index: usize,
    drawable: &WgpuDrawableBuffers,
    mesh: &Moc3DrawableMesh,
) -> Result<(), WgpuMeshUpdateError> {
    validate_count(
        drawable.vertex_count as usize,
        mesh.vertices().len(),
        WgpuMeshUpdateError::VertexCount {
            drawable_index,
            expected: drawable.vertex_count as usize,
            actual: mesh.vertices().len(),
        },
    )?;
    validate_count(
        drawable.index_count as usize,
        mesh.indices().len(),
        WgpuMeshUpdateError::IndexCount {
            drawable_index,
            expected: drawable.index_count as usize,
            actual: mesh.indices().len(),
        },
    )?;
    validate_unchanged(
        drawable.indices.as_slice(),
        mesh.indices(),
        WgpuMeshUpdateError::Indices { drawable_index },
    )?;
    validate_unchanged(
        &drawable.texture_index(),
        &mesh.texture_index(),
        WgpuMeshUpdateError::TextureIndex {
            drawable_index,
            expected: drawable.texture_index(),
            actual: mesh.texture_index(),
        },
    )?;
    validate_unchanged(
        &drawable.blend_mode(),
        &mesh.blend_mode(),
        WgpuMeshUpdateError::BlendMode {
            drawable_index,
            expected: drawable.blend_mode(),
            actual: mesh.blend_mode(),
        },
    )?;
    validate_unchanged(
        drawable.masks(),
        mesh.masks(),
        WgpuMeshUpdateError::Masks { drawable_index },
    )?;
    validate_unchanged(
        &drawable.inverted_mask(),
        &mesh.is_inverted_mask(),
        WgpuMeshUpdateError::InvertedMask {
            drawable_index,
            expected: drawable.inverted_mask(),
            actual: mesh.is_inverted_mask(),
        },
    )?;

    Ok(())
}

fn validate_count(
    expected: usize,
    actual: usize,
    error: WgpuMeshUpdateError,
) -> Result<(), WgpuMeshUpdateError> {
    if expected == actual {
        Ok(())
    } else {
        Err(error)
    }
}

fn validate_unchanged<T: PartialEq + ?Sized>(
    expected: &T,
    actual: &T,
    error: WgpuMeshUpdateError,
) -> Result<(), WgpuMeshUpdateError> {
    if expected == actual {
        Ok(())
    } else {
        Err(error)
    }
}

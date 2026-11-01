use wgpu::util::DeviceExt;

use crate::core::Matrix44;

use crate::render::common::{ClippingLayout as WgpuClippingLayout, MaskChannel as WgpuMaskChannel};

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum WgpuTextureError {
    #[error("invalid texture size {width}x{height}")]
    InvalidTextureSize { width: u32, height: u32 },
    #[error("invalid rgba8 texture length for {width}x{height}: expected {expected}, got {actual}")]
    InvalidRgbaLength {
        width: u32,
        height: u32,
        expected: usize,
        actual: usize,
    },
}

#[derive(Debug)]
pub struct WgpuTexture {
    pub(super) texture: wgpu::Texture,
    pub(super) view: wgpu::TextureView,
    pub(super) bind_group: wgpu::BindGroup,
    pub(super) width: u32,
    pub(super) height: u32,
}

impl WgpuTexture {
    pub fn texture(&self) -> &wgpu::Texture {
        &self.texture
    }

    pub fn view(&self) -> &wgpu::TextureView {
        &self.view
    }

    pub fn bind_group(&self) -> &wgpu::BindGroup {
        &self.bind_group
    }

    pub fn width(&self) -> u32 {
        self.width
    }

    pub fn height(&self) -> u32 {
        self.height
    }
}

#[derive(Debug)]
pub struct WgpuTransform {
    buffer: wgpu::Buffer,
    bind_group: wgpu::BindGroup,
    bytes: Vec<u8>,
}

impl WgpuTransform {
    pub fn buffer(&self) -> &wgpu::Buffer {
        &self.buffer
    }

    pub fn bind_group(&self) -> &wgpu::BindGroup {
        &self.bind_group
    }

    pub fn update_matrix(&mut self, queue: &wgpu::Queue, matrix: &Matrix44) -> bool {
        let next = encode_wgpu_matrix_bytes(matrix);
        update_uniform_bytes(queue, &self.buffer, &mut self.bytes, &next)
    }
}

#[derive(Debug)]
pub struct WgpuMaskParams {
    buffer: wgpu::Buffer,
    bind_group: wgpu::BindGroup,
    bytes: Vec<u8>,
}

impl WgpuMaskParams {
    pub fn buffer(&self) -> &wgpu::Buffer {
        &self.buffer
    }

    pub fn bind_group(&self) -> &wgpu::BindGroup {
        &self.bind_group
    }

    pub fn update_layout(&mut self, queue: &wgpu::Queue, layout: WgpuClippingLayout) -> bool {
        let next = encode_wgpu_mask_param_bytes(layout);
        update_uniform_bytes(queue, &self.buffer, &mut self.bytes, &next)
    }
}

#[derive(Debug)]
pub struct WgpuClipParams {
    buffer: wgpu::Buffer,
    bind_group: wgpu::BindGroup,
    bytes: Vec<u8>,
}

impl WgpuClipParams {
    pub fn buffer(&self) -> &wgpu::Buffer {
        &self.buffer
    }

    pub fn bind_group(&self) -> &wgpu::BindGroup {
        &self.bind_group
    }

    pub fn update_params(
        &mut self,
        queue: &wgpu::Queue,
        matrix: &Matrix44,
        channel: WgpuMaskChannel,
        inverted: bool,
    ) -> bool {
        let next = encode_wgpu_clip_param_bytes(matrix, channel, inverted);
        update_uniform_bytes(queue, &self.buffer, &mut self.bytes, &next)
    }
}

fn update_uniform_bytes(
    queue: &wgpu::Queue,
    buffer: &wgpu::Buffer,
    current: &mut Vec<u8>,
    next: &[u8],
) -> bool {
    if current.as_slice() == next {
        return false;
    }

    queue.write_buffer(buffer, 0, next);
    current.clear();
    current.extend_from_slice(next);
    true
}

pub fn encode_wgpu_matrix(matrix: &Matrix44) -> Vec<u8> {
    encode_wgpu_matrix_bytes(matrix).to_vec()
}

pub fn encode_wgpu_mask_params(layout: WgpuClippingLayout) -> Vec<u8> {
    encode_wgpu_mask_param_bytes(layout).to_vec()
}

pub fn encode_wgpu_clip_params(
    matrix: &Matrix44,
    channel: WgpuMaskChannel,
    inverted: bool,
) -> Vec<u8> {
    encode_wgpu_clip_param_bytes(matrix, channel, inverted).to_vec()
}

fn encode_wgpu_matrix_bytes(matrix: &Matrix44) -> [u8; 64] {
    let mut bytes = [0; 64];
    for (index, &value) in matrix.as_slice().iter().enumerate() {
        write_f32(&mut bytes, index * 4, value);
    }
    bytes
}

fn encode_wgpu_mask_param_bytes(layout: WgpuClippingLayout) -> [u8; 32] {
    let bounds = layout.bounds();
    let base_rect = [
        bounds.x() * 2.0 - 1.0,
        bounds.y() * 2.0 - 1.0,
        (bounds.x() + bounds.width()) * 2.0 - 1.0,
        (bounds.y() + bounds.height()) * 2.0 - 1.0,
    ];
    let mut bytes = [0; 32];

    for (index, value) in layout
        .channel_flag()
        .into_iter()
        .chain(base_rect)
        .enumerate()
    {
        write_f32(&mut bytes, index * 4, value);
    }

    bytes
}

fn encode_wgpu_clip_param_bytes(
    matrix: &Matrix44,
    channel: WgpuMaskChannel,
    inverted: bool,
) -> [u8; 96] {
    let mut bytes = [0; 96];
    bytes[..64].copy_from_slice(&encode_wgpu_matrix_bytes(matrix));
    let inverted_flag = [if inverted { 1.0 } else { 0.0 }, 0.0, 0.0, 0.0];
    for (index, value) in channel.flag().into_iter().chain(inverted_flag).enumerate() {
        write_f32(&mut bytes, 64 + index * 4, value);
    }

    bytes
}

fn write_f32(bytes: &mut [u8], offset: usize, value: f32) {
    bytes[offset..offset + 4].copy_from_slice(&value.to_ne_bytes());
}

pub(super) fn create_wgpu_mask_params(
    device: &wgpu::Device,
    bind_group_layout: &wgpu::BindGroupLayout,
    layout: WgpuClippingLayout,
) -> WgpuMaskParams {
    let bytes = encode_wgpu_mask_params(layout);
    let buffer = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
        label: Some("live2d.mask.params.uniform"),
        contents: &bytes,
        usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
    });
    let bind_group = device.create_bind_group(&wgpu::BindGroupDescriptor {
        label: Some("live2d.mask.params.bind_group"),
        layout: bind_group_layout,
        entries: &[wgpu::BindGroupEntry {
            binding: 0,
            resource: buffer.as_entire_binding(),
        }],
    });

    WgpuMaskParams {
        buffer,
        bind_group,
        bytes,
    }
}

pub(super) fn create_wgpu_clip_params(
    device: &wgpu::Device,
    bind_group_layout: &wgpu::BindGroupLayout,
    matrix: &Matrix44,
    channel: WgpuMaskChannel,
    inverted: bool,
) -> WgpuClipParams {
    let bytes = encode_wgpu_clip_params(matrix, channel, inverted);
    let buffer = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
        label: Some("live2d.clip.params.uniform"),
        contents: &bytes,
        usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
    });
    let bind_group = device.create_bind_group(&wgpu::BindGroupDescriptor {
        label: Some("live2d.clip.params.bind_group"),
        layout: bind_group_layout,
        entries: &[wgpu::BindGroupEntry {
            binding: 0,
            resource: buffer.as_entire_binding(),
        }],
    });

    WgpuClipParams {
        buffer,
        bind_group,
        bytes,
    }
}

pub(super) fn create_wgpu_transform(
    device: &wgpu::Device,
    bind_group_layout: &wgpu::BindGroupLayout,
    matrix: &Matrix44,
) -> WgpuTransform {
    let matrix_bytes = encode_wgpu_matrix(matrix);
    let buffer = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
        label: Some("live2d.transform.uniform"),
        contents: &matrix_bytes,
        usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
    });
    let bind_group = device.create_bind_group(&wgpu::BindGroupDescriptor {
        label: Some("live2d.transform.bind_group"),
        layout: bind_group_layout,
        entries: &[wgpu::BindGroupEntry {
            binding: 0,
            resource: buffer.as_entire_binding(),
        }],
    });

    WgpuTransform {
        buffer,
        bind_group,
        bytes: matrix_bytes,
    }
}

pub(super) fn rgba8_len(width: u32, height: u32) -> Result<usize, WgpuTextureError> {
    if width == 0 || height == 0 {
        return Err(WgpuTextureError::InvalidTextureSize { width, height });
    }

    let len = usize::try_from(width)
        .ok()
        .and_then(|width| {
            usize::try_from(height)
                .ok()
                .and_then(|height| width.checked_mul(height))
        })
        .and_then(|pixels| pixels.checked_mul(4))
        .ok_or(WgpuTextureError::InvalidTextureSize { width, height })?;

    Ok(len)
}

/// Number of mip levels in a full chain down to 1×1.
pub(super) fn full_mip_level_count(width: u32, height: u32) -> u32 {
    32 - width.max(height).leading_zeros()
}

/// Downsamples one RGBA8 mip level into the next (half size, 2×2 box filter).
///
/// Live2D textures use straight (non-premultiplied) alpha, so color channels
/// are weighted by alpha before averaging: a plain average would bleed the
/// color of fully transparent texels into edge mips and produce dark fringes.
pub(super) fn next_mip_rgba8(src: &[u8], src_width: u32, src_height: u32) -> (Vec<u8>, u32, u32) {
    let dst_width = (src_width / 2).max(1);
    let dst_height = (src_height / 2).max(1);
    let mut dst = vec![0u8; dst_width as usize * dst_height as usize * 4];

    for y in 0..dst_height {
        let sy0 = (y * 2).min(src_height - 1);
        let sy1 = (y * 2 + 1).min(src_height - 1);
        for x in 0..dst_width {
            let sx0 = (x * 2).min(src_width - 1);
            let sx1 = (x * 2 + 1).min(src_width - 1);

            let mut rgb_weighted = [0u32; 3];
            let mut rgb_plain = [0u32; 3];
            let mut alpha_sum = 0u32;
            for (sx, sy) in [(sx0, sy0), (sx1, sy0), (sx0, sy1), (sx1, sy1)] {
                let offset = ((sy * src_width + sx) * 4) as usize;
                let alpha = u32::from(src[offset + 3]);
                for channel in 0..3 {
                    let value = u32::from(src[offset + channel]);
                    rgb_weighted[channel] += value * alpha;
                    rgb_plain[channel] += value;
                }
                alpha_sum += alpha;
            }

            let out = ((y * dst_width + x) * 4) as usize;
            for channel in 0..3 {
                dst[out + channel] =
                    match (rgb_weighted[channel] + alpha_sum / 2).checked_div(alpha_sum) {
                        Some(weighted) => weighted as u8,
                        // Fully transparent quad: keep a plain color average so
                        // the (invisible) color stays stable instead of black.
                        None => ((rgb_plain[channel] + 2) / 4) as u8,
                    };
            }
            dst[out + 3] = ((alpha_sum + 2) / 4) as u8;
        }
    }

    (dst, dst_width, dst_height)
}

#[cfg(test)]
mod tests {
    use super::{full_mip_level_count, next_mip_rgba8};

    #[test]
    fn full_mip_level_count_covers_chain_to_one_pixel() {
        assert_eq!(full_mip_level_count(1, 1), 1);
        assert_eq!(full_mip_level_count(2, 2), 2);
        assert_eq!(full_mip_level_count(4096, 2048), 13);
        assert_eq!(full_mip_level_count(5, 3), 3);
    }

    #[test]
    fn next_mip_weights_color_by_alpha() {
        // Opaque white + three transparent black texels: a plain average
        // would give dark gray, alpha weighting must keep the color white.
        let src = [
            255, 255, 255, 255, // opaque white
            0, 0, 0, 0, // transparent black
            0, 0, 0, 0, //
            0, 0, 0, 0, //
        ];
        let (dst, w, h) = next_mip_rgba8(&src, 2, 2);
        assert_eq!((w, h), (1, 1));
        assert_eq!(&dst[0..3], &[255, 255, 255]);
        assert_eq!(dst[3], 64); // 255 / 4, rounded
    }

    #[test]
    fn next_mip_fully_transparent_averages_plain_color() {
        let src = [
            10, 20, 30, 0, //
            10, 20, 30, 0, //
            10, 20, 30, 0, //
            10, 20, 30, 0, //
        ];
        let (dst, _, _) = next_mip_rgba8(&src, 2, 2);
        assert_eq!(&dst[..], &[10, 20, 30, 0]);
    }

    #[test]
    fn next_mip_handles_odd_dimensions_by_clamping() {
        // 3×1 → 1×1; the third column is dropped, edge texels clamp.
        let src = [
            100, 100, 100, 255, //
            200, 200, 200, 255, //
            0, 0, 0, 255, //
        ];
        let (dst, w, h) = next_mip_rgba8(&src, 3, 1);
        assert_eq!((w, h), (1, 1));
        assert_eq!(&dst[..], &[150, 150, 150, 255]);
    }
}

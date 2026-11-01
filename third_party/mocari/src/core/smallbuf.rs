//! Fixed-capacity inline buffer with heap spill, for per-frame hot paths.

/// A small, `Copy`-element buffer that stores up to `N` items inline and
/// falls back to a heap `Vec` only when the capacity is exceeded. Used to
/// avoid per-frame heap allocations in keyform slot evaluation, where the
/// element count is almost always tiny (typically `1 << active_axes`).
#[derive(Debug, Clone)]
pub enum SmallBuf<T: Copy + Default, const N: usize> {
    Inline { buf: [T; N], len: usize },
    Heap(Vec<T>),
}

impl<T: Copy + Default, const N: usize> SmallBuf<T, N> {
    pub fn new() -> Self {
        Self::Inline {
            buf: [T::default(); N],
            len: 0,
        }
    }

    pub fn push(&mut self, value: T) {
        match self {
            Self::Inline { buf, len } => {
                if *len < N {
                    buf[*len] = value;
                    *len += 1;
                } else {
                    let mut spill = Vec::with_capacity(N * 2);
                    spill.extend_from_slice(&buf[..*len]);
                    spill.push(value);
                    *self = Self::Heap(spill);
                }
            }
            Self::Heap(vec) => vec.push(value),
        }
    }

    pub fn as_slice(&self) -> &[T] {
        match self {
            Self::Inline { buf, len } => &buf[..*len],
            Self::Heap(vec) => vec.as_slice(),
        }
    }
}

impl<T: Copy + Default, const N: usize> Default for SmallBuf<T, N> {
    fn default() -> Self {
        Self::new()
    }
}

impl<T: Copy + Default, const N: usize> std::ops::Deref for SmallBuf<T, N> {
    type Target = [T];

    fn deref(&self) -> &[T] {
        self.as_slice()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stays_inline_up_to_capacity() {
        let mut buf = SmallBuf::<u32, 4>::new();
        for value in 0..4 {
            buf.push(value);
        }
        assert!(matches!(buf, SmallBuf::Inline { len: 4, .. }));
        assert_eq!(buf.as_slice(), &[0, 1, 2, 3]);
    }

    #[test]
    fn spills_to_heap_beyond_capacity_preserving_order() {
        let mut buf = SmallBuf::<u32, 2>::new();
        for value in 0..5 {
            buf.push(value);
        }
        assert!(matches!(buf, SmallBuf::Heap(_)));
        assert_eq!(buf.as_slice(), &[0, 1, 2, 3, 4]);
    }

    #[test]
    fn empty_buffer_yields_empty_slice() {
        let buf = SmallBuf::<u32, 4>::new();
        assert!(buf.as_slice().is_empty());
        assert!(buf.is_empty());
    }
}

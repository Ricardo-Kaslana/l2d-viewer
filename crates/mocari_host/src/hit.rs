pub struct HitArea {
    pub id: String,
    pub min_x: f32,
    pub max_x: f32,
    pub min_y: f32,
    pub max_y: f32,
    pub target: String,
}

pub struct HitResult;
impl HitResult {
    pub fn resolve(areas: &[HitArea], x: f32, y: f32) -> Option<String> {
        areas
            .iter()
            .find(|a| x >= a.min_x && x <= a.max_x && y >= a.min_y && y <= a.max_y)
            .map(|a| a.target.clone())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hit_returns_motion_group_when_inside() {
        let areas = vec![HitArea {
            id: "head".into(),
            min_x: 0.4,
            max_x: 0.6,
            min_y: 0.6,
            max_y: 0.9,
            target: "tap_head".into(),
        }];
        let r = HitResult::resolve(&areas, 0.5, 0.8).expect("hit");
        assert_eq!(r, "tap_head");
    }

    #[test]
    fn miss_returns_none() {
        let areas = vec![HitArea {
            id: "head".into(),
            min_x: 0.4,
            max_x: 0.6,
            min_y: 0.6,
            max_y: 0.9,
            target: "tap_head".into(),
        }];
        assert!(HitResult::resolve(&areas, 0.1, 0.1).is_none());
    }
}

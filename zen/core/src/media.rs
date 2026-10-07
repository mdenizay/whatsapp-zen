//! Pictures and web pages the core has to look into itself: link previews,
//! their thumbnails, and stickers made from an image.

use std::io::Cursor;
use std::time::Duration;

use image::imageops::FilterType;

pub struct LinkPreview {
    pub url: String,
    pub title: String,
    pub description: String,
    pub thumb: Option<Vec<u8>>,
}

fn http_get(url: &str, limit: u64) -> Option<Vec<u8>> {
    let agent: ureq::Agent = ureq::Agent::config_builder().timeout_global(Some(Duration::from_secs(4))).build().into();
    // Many sites only send their preview tags to something that looks like a browser.
    let response = agent.get(url).header("User-Agent", "Mozilla/5.0 (Macintosh) WhatsApp/2").call().ok()?;
    let data = response.into_body().into_with_config().limit(limit).read_to_vec().ok()?;
    (!data.is_empty()).then_some(data)
}

/// The value of `name="…"` inside one tag, whatever the quote style.
fn attribute(tag: &str, name: &str) -> Option<String> {
    let lower = tag.to_lowercase();
    let mut from = 0;
    while let Some(found) = lower[from..].find(name) {
        let at = from + found;
        let boundary = at == 0 || !lower.as_bytes()[at - 1].is_ascii_alphanumeric();
        let rest = tag[at + name.len()..].trim_start();
        if boundary && rest.starts_with('=') {
            let value = rest[1..].trim_start();
            let quote = value.chars().next()?;
            if quote == '"' || quote == '\'' {
                return value[1..].find(quote).map(|end| value[1..1 + end].to_string());
            }
        }
        from = at + name.len();
    }
    None
}

/// Reads the title, description and picture of the first link in a message.
/// It gives up quickly: a preview must not delay sending.
pub fn link_preview(text: &str) -> Option<LinkPreview> {
    let start = text.find("https://").or_else(|| text.find("http://"))?;
    let url: String = text[start..].chars().take_while(|c| !c.is_whitespace()).collect();
    let page = String::from_utf8_lossy(&http_get(&url, 512 << 10)?).into_owned();
    let lower = page.to_lowercase();
    let (mut title, mut description, mut picture) = (String::new(), String::new(), String::new());
    let mut from = 0;
    while let Some(found) = lower[from..].find("<meta") {
        let at = from + found;
        let Some(end) = lower[at..].find('>') else { break };
        let tag = &page[at..at + end];
        let key = attribute(tag, "property").or_else(|| attribute(tag, "name")).unwrap_or_default().to_lowercase();
        let content = attribute(tag, "content").unwrap_or_default();
        match key.as_str() {
            "og:title" => title = content,
            "og:description" | "description" if description.is_empty() => description = content,
            "og:image" => picture = content,
            _ => {}
        }
        from = at + end;
    }
    if title.is_empty() {
        if let (Some(open), Some(close)) = (lower.find("<title"), lower.find("</title>")) {
            if let Some(gt) = page[open..close].find('>') {
                title = page[open + gt + 1..close].trim().to_string();
            }
        }
    }
    if title.is_empty() {
        return None;
    }
    let thumb = picture.starts_with("http").then(|| http_get(&picture, 3 << 20)).flatten().and_then(|data| jpeg_thumb(&data, 160));
    Some(LinkPreview { url, title, description, thumb })
}

/// Shrinks a picture to at most `max` pixels wide, as a JPEG.
pub fn jpeg_thumb(data: &[u8], max: u32) -> Option<Vec<u8>> {
    let picture = image::load_from_memory(data).ok()?;
    let small = if picture.width() > max { picture.resize(max, u32::MAX, FilterType::Triangle) } else { picture };
    let mut out = Vec::new();
    let encoder = image::codecs::jpeg::JpegEncoder::new_with_quality(&mut out, 60);
    small.to_rgb8().write_with_encoder(encoder).ok()?;
    Some(out)
}

/// Turns a square PNG with transparent padding into a WebP sticker. The
/// encoder is lossless, so a photo can come out large; the size is stepped
/// down until the sticker is light enough to be accepted everywhere.
pub fn sticker(png: &[u8]) -> Result<(Vec<u8>, u32), String> {
    let source = image::load_from_memory(png).map_err(|e| e.to_string())?;
    let mut last = (Vec::new(), 512);
    for side in [512u32, 384, 256, 192] {
        let scaled = source.resize_exact(side, side, FilterType::Triangle).to_rgba8();
        let mut out = Cursor::new(Vec::new());
        scaled.write_with_encoder(image::codecs::webp::WebPEncoder::new_lossless(&mut out)).map_err(|e| e.to_string())?;
        last = (out.into_inner(), side);
        if last.0.len() <= 300 << 10 {
            break;
        }
    }
    Ok(last)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sticker_is_a_small_webp() {
        // A photo-like square: lossless WebP of noise is the worst case.
        let noisy = image::RgbaImage::from_fn(600, 600, |x, y| image::Rgba([(x * 7 % 256) as u8, (y * 13 % 256) as u8, ((x ^ y) % 256) as u8, 255]));
        let mut png = Cursor::new(Vec::new());
        noisy.write_to(&mut png, image::ImageFormat::Png).unwrap();
        let (webp, side) = sticker(png.get_ref()).unwrap();
        assert_eq!(&webp[..4], b"RIFF");
        assert_eq!(&webp[8..12], b"WEBP");
        assert!([512, 384, 256, 192].contains(&side));
        assert_eq!(image::load_from_memory(&webp).unwrap().width(), side);
    }

    #[test]
    fn thumbnail_is_a_narrow_jpeg() {
        let wide = image::RgbImage::from_pixel(800, 400, image::Rgb([200, 80, 40]));
        let mut png = Cursor::new(Vec::new());
        wide.write_to(&mut png, image::ImageFormat::Png).unwrap();
        let thumb = jpeg_thumb(png.get_ref(), 160).unwrap();
        let decoded = image::load_from_memory(&thumb).unwrap();
        assert_eq!((decoded.width(), decoded.height()), (160, 80));
    }

    #[test]
    fn reads_attributes_in_either_quote_style() {
        assert_eq!(attribute(r#"<meta property="og:title" content="Hello there""#, "content").as_deref(), Some("Hello there"));
        assert_eq!(attribute("<meta name='description' content='It''s'", "name").as_deref(), Some("description"));
        assert_eq!(attribute(r#"<meta content="x""#, "property"), None);
    }

    /// Needs the network: `cargo test -- --ignored`.
    #[test]
    #[ignore]
    fn previews_a_real_page() {
        let preview = link_preview("see https://github.com/mdenizay/whatsapp-zen please").unwrap();
        assert!(!preview.title.is_empty());
        assert_eq!(preview.url, "https://github.com/mdenizay/whatsapp-zen");
    }
}

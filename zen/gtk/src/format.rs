//! WhatsApp's text formatting as Pango markup: *bold*, _italic_,
//! ~strikethrough~, `code` and ```monospace``` blocks, with links made
//! clickable. Markers only count at word edges, as on the phone, so
//! snake_case and 2*3*4 stay as typed. The same rules as the macOS app.

/// Markdown's doubled markers (**bold**, __italic__, ~~strike~~), common in
/// pasted text, as WhatsApp's single ones.
pub fn normalized(text: &str) -> String {
    let mut out = text.to_string();
    for marker in ["**", "__", "~~"] {
        let single = &marker[..1];
        let mut result = String::new();
        let mut rest = out.as_str();
        while let Some(start) = rest.find(marker) {
            let after = &rest[start + 2..];
            match after.find(marker) {
                Some(end) if end > 0 && !after[..end].contains('\n') && !after.starts_with(char::is_whitespace) && !after[..end].ends_with(char::is_whitespace) => {
                    result.push_str(&rest[..start]);
                    result.push_str(single);
                    result.push_str(&after[..end]);
                    result.push_str(single);
                    rest = &after[end + 2..];
                }
                _ => {
                    result.push_str(&rest[..start + 2]);
                    rest = after;
                }
            }
        }
        result.push_str(rest);
        out = result;
    }
    out
}

fn escape(text: &str) -> String {
    text.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;")
}

/// Where links are, as ranges of character indexes.
fn links(chars: &[char]) -> Vec<(usize, usize)> {
    let mut found = Vec::new();
    let mut i = 0;
    while i < chars.len() {
        let at_word = i == 0 || chars[i - 1].is_whitespace() || "(<[\"'".contains(chars[i - 1]);
        let starts = |prefix: &str| chars[i..].iter().take(prefix.len()).collect::<String>().eq_ignore_ascii_case(prefix);
        if at_word && (starts("https://") || starts("http://") || starts("www.")) {
            let mut end = i;
            while end < chars.len() && !chars[end].is_whitespace() {
                end += 1;
            }
            // Punctuation after a link belongs to the sentence.
            while end > i && ".,;:!?)\"'".contains(chars[end - 1]) {
                end -= 1;
            }
            found.push((i, end));
            i = end;
        } else {
            i += 1;
        }
    }
    found
}

/// Pango markup for a message's text.
pub fn markup(raw: &str) -> String {
    let text = normalized(raw);
    let chars: Vec<char> = text.chars().collect();
    let links = links(&chars);
    let in_link = |i: usize| links.iter().any(|&(a, b)| (a..b).contains(&i));
    let word = |c: char| c.is_alphanumeric();

    let mut out = String::new();
    let emit = |out: &mut String, lo: usize, hi: usize| {
        let mut i = lo;
        while i < hi {
            if let Some(&(a, b)) = links.iter().find(|&&(a, b)| (a..b).contains(&i)) {
                let end = b.min(hi);
                let target: String = chars[a..b].iter().collect();
                let href = if target.to_lowercase().starts_with("www.") { format!("https://{target}") } else { target };
                out.push_str(&format!("<a href=\"{}\">{}</a>", escape(&href), escape(&chars[i..end].iter().collect::<String>())));
                i = end;
            } else {
                let next = links.iter().map(|&(a, _)| a).filter(|&a| a > i).min().unwrap_or(hi).min(hi);
                out.push_str(&escape(&chars[i..next].iter().collect::<String>()));
                i = next;
            }
        }
    };

    // Where a marker opened at `i` closes, on the same line.
    let closing = |marker: char, i: usize, hi: usize| -> Option<usize> {
        if i > 0 && word(chars[i - 1]) {
            return None;
        }
        if i + 1 >= hi || chars[i + 1].is_whitespace() || chars[i + 1] == marker {
            return None;
        }
        let mut j = i + 2;
        while j < hi {
            let c = chars[j];
            if c == '\n' {
                return None;
            }
            if c == marker && !chars[j - 1].is_whitespace() && (j + 1 == hi || !word(chars[j + 1])) && !in_link(j) {
                return Some(j);
            }
            j += 1;
        }
        None
    };

    fn parse(out: &mut String, lo: usize, hi: usize, chars: &[char], emit: &dyn Fn(&mut String, usize, usize), closing: &dyn Fn(char, usize, usize) -> Option<usize>, in_link: &dyn Fn(usize) -> bool) {
        let mut i = lo;
        let mut plain = lo;
        while i < hi {
            let c = chars[i];
            if !"*_~`".contains(c) || in_link(i) {
                i += 1;
                continue;
            }
            // ```a block```, which may span lines and is never formatted inside.
            if c == '`' && i + 2 < hi && chars[i + 1] == '`' && chars[i + 2] == '`' {
                let mut k = i + 3;
                while k + 2 < hi && !(chars[k] == '`' && chars[k + 1] == '`' && chars[k + 2] == '`') {
                    k += 1;
                }
                if k + 2 < hi && k > i + 3 {
                    emit(out, plain, i);
                    out.push_str("<tt>");
                    out.push_str(&escape(&chars[i + 3..k].iter().collect::<String>()));
                    out.push_str("</tt>");
                    i = k + 3;
                    plain = i;
                    continue;
                }
                i += 3;
                continue;
            }
            let Some(j) = closing(c, i, hi) else {
                i += 1;
                continue;
            };
            emit(out, plain, i);
            let tag = match c {
                '*' => "b",
                '_' => "i",
                '~' => "s",
                _ => "tt",
            };
            out.push_str(&format!("<{tag}>"));
            if tag == "tt" {
                out.push_str(&escape(&chars[i + 1..j].iter().collect::<String>()));
            } else {
                parse(out, i + 1, j, chars, emit, closing, in_link);
            }
            out.push_str(&format!("</{tag}>"));
            i = j + 1;
            plain = i;
        }
        emit(out, plain, hi);
    }

    parse(&mut out, 0, chars.len(), &chars, &emit, &closing, &in_link);
    out
}

/// The text without its markers, for one-line previews.
pub fn plain(raw: &str) -> String {
    let markup = markup(raw);
    let mut out = String::new();
    let mut in_tag = false;
    for c in markup.chars() {
        match c {
            '<' => in_tag = true,
            '>' => in_tag = false,
            _ if !in_tag => out.push(c),
            _ => {}
        }
    }
    out.replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", "\"").replace("&amp;", "&")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn formats_like_the_phone() {
        assert_eq!(markup("*bold* and _it_"), "<b>bold</b> and <i>it</i>");
        assert_eq!(markup("~gone~ `x = 1`"), "<s>gone</s> <tt>x = 1</tt>");
        assert_eq!(markup("snake_case_name 2*3*4"), "snake_case_name 2*3*4");
        assert_eq!(markup("*bold _both_*"), "<b>bold <i>both</i></b>");
        assert_eq!(markup("**markdown**"), "<b>markdown</b>");
        assert_eq!(markup("a < b & c"), "a &lt; b &amp; c");
        assert_eq!(markup("```let a = *b*```"), "<tt>let a = *b*</tt>");
    }

    #[test]
    fn links() {
        assert_eq!(markup("see https://example.com/a_b_c."), "see <a href=\"https://example.com/a_b_c\">https://example.com/a_b_c</a>.");
        assert_eq!(markup("www.example.com"), "<a href=\"https://www.example.com\">www.example.com</a>");
    }

    #[test]
    fn plain_previews() {
        assert_eq!(plain("*hi* <there>"), "hi <there>");
    }
}

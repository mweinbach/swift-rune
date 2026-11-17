//! Browser bridge to the same Hunspell implementation used by Rune upstream.
//! Each WebAssembly instance owns its dictionaries and one synchronous transfer buffer.
use spellbook::Dictionary;
use std::{cell::RefCell, str};
use unicode_segmentation::UnicodeSegmentation;

#[derive(Default)]
struct Engine {
    dictionaries: Vec<Option<Box<Dictionary>>>,
    bytes: Vec<u8>,
    ranges: Vec<u32>,
}

thread_local! {
    static ENGINE: RefCell<Engine> = RefCell::default();
}

#[unsafe(no_mangle)]
pub extern "C" fn spell_buffer(length: usize) -> *mut u8 {
    ENGINE.with_borrow_mut(|state| {
        let extra = length.saturating_sub(state.bytes.len());
        if state.bytes.try_reserve(extra).is_err() {
            return std::ptr::null_mut();
        }
        state.bytes.resize(length, 0);
        state.bytes.as_mut_ptr()
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn spell_bytes() -> *const u8 {
    ENGINE.with_borrow(|state| state.bytes.as_ptr())
}

#[unsafe(no_mangle)]
pub extern "C" fn spell_length() -> usize {
    ENGINE.with_borrow(|state| state.bytes.len())
}

#[unsafe(no_mangle)]
pub extern "C" fn spell_open(aff_length: usize) -> usize {
    ENGINE.with_borrow_mut(|state| {
        let parse = || {
            let (aff, dic) = state
                .bytes
                .split_at_checked(aff_length)
                .ok_or("invalid affix length")?;
            let aff = str::from_utf8(aff).map_err(|_| "affix file is not UTF-8")?;
            let dic = str::from_utf8(dic).map_err(|_| "dictionary file is not UTF-8")?;
            Dictionary::new(aff, dic).map_err(|error| error.to_string())
        };
        let result = parse();
        // Dictionary inputs can span megabytes; release them before checking individual words.
        state.bytes = Vec::new();
        let dictionary = match result {
            Ok(dictionary) => Box::new(dictionary),
            Err(message) => {
                state.bytes = message.into_bytes();
                return 0;
            }
        };
        if let Some((index, slot)) = state
            .dictionaries
            .iter_mut()
            .enumerate()
            .find(|(_, d)| d.is_none())
        {
            *slot = Some(dictionary);
            index + 1
        } else {
            state.dictionaries.push(Some(dictionary));
            state.dictionaries.len()
        }
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn spell_close(id: usize) {
    ENGINE.with_borrow_mut(|state| {
        if let Some(slot) = state.dictionaries.get_mut(id.wrapping_sub(1)) {
            *slot = None;
        }
        while state.dictionaries.last().is_some_and(Option::is_none) {
            state.dictionaries.pop();
        }
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn spell_check(id: usize) -> bool {
    ENGINE.with_borrow(|state| {
        let Some(Some(dictionary)) = state.dictionaries.get(id.wrapping_sub(1)) else {
            return false;
        };
        str::from_utf8(&state.bytes).is_ok_and(|word| dictionary.check(word))
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn spell_add(id: usize) -> bool {
    ENGINE.with_borrow_mut(|state| {
        let Some(Some(dictionary)) = state.dictionaries.get_mut(id.wrapping_sub(1)) else {
            return false;
        };
        str::from_utf8(&state.bytes).is_ok_and(|word| dictionary.add(word).is_ok())
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn spell_suggest(id: usize) {
    ENGINE.with_borrow_mut(|state| {
        let mut words = Vec::new();
        if let Some(Some(dictionary)) = state.dictionaries.get(id.wrapping_sub(1))
            && let Ok(word) = str::from_utf8(&state.bytes)
        {
            dictionary.suggest(word, &mut words);
        }
        state.bytes.clear();
        for word in words {
            state
                .bytes
                .extend_from_slice(&(word.len() as u32).to_le_bytes());
            state.bytes.extend_from_slice(word.as_bytes());
        }
    })
}

/// Rune's browser checker uses Unicode word-break boundaries even where a browser may
/// apply a locale-specific dictionary breaker. Offsets are UTF-8 bytes in the original line.
#[unsafe(no_mangle)]
pub extern "C" fn spell_prose() -> *const u32 {
    ENGINE.with_borrow_mut(|state| {
        state.ranges.clear();
        if let Ok(text) = str::from_utf8(&state.bytes) {
            for chunk in text.split_whitespace() {
                if chunk.contains(['/', '@', '`', '_', '\\', '=', '<', '>', '{', '}'])
                    || chunk.contains("::")
                {
                    continue;
                }
                let start = chunk.as_ptr() as usize - text.as_ptr() as usize;
                for (at, word) in chunk.split_word_bound_indices() {
                    if worth_checking(word) {
                        state.ranges.push((start + at) as u32);
                        state.ranges.push((start + at + word.len()) as u32);
                    }
                }
            }
        }
        state.ranges.as_ptr()
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn spell_prose_length() -> usize {
    ENGINE.with_borrow(|state| state.ranges.len())
}

fn worth_checking(word: &str) -> bool {
    let mut letters = 0;
    for (offset, c) in word.char_indices() {
        if c.is_alphabetic() {
            if offset != 0 && c.is_uppercase() {
                return false;
            }
            letters += 1;
        } else if c != '\'' && c != '’' {
            return false;
        }
    }
    letters >= 2
}

# Part 5: Exact Source Provenance Test Suite

## Basic Elements with Source Mapping

Some **bold text** and a [link label](https://example.com) here.

This line has multiple links: [first](https://one.com), [second](https://two.com), and [third](https://three.com).

## UTF-8 and Multi-byte Characters

Unicode line: café 日本語 🎉 done.

Emoji test: 🚀 rocket, 🎨 art, 🌍 earth, 😀 smile.

CJK characters: 中文 日本語 한국어 mixed together.

Combining characters: e̊ å ñ ü with diacritics.

## Repeated Text Elements

Repeated: apple banana apple banana apple

The word "test" appears here test and here test and again test.

## Nested Emphasis and Formatting

Nested *emphasis with **strong** inside* trailing.

Mixed ***bold and italic*** and `code with **bold** inside`.

Inline `code span` and entity a &amp; b and escape \*star\*.

## Links and References

A [reference link][ref] and an autolink <https://example.org/auto>.

Link [target](https://example.com/target) and target outside.

[Email link](mailto:test@example.com) and [ftp link](ftp://ftp.example.com/file).

Direct URL: http://example.org/bare inside text.

Autolink with path <https://example.com/path/to/page>.

## Entities and Special Characters

Entities beside multibyte: 日本語&amp;日本語 done.

HTML entities: &lt; less than, &gt; greater than, &quot; quote, &apos; apostrophe.

Numeric entities: &#169; copyright, &#8364; euro, &#x1F4A9; pile.

Mixed: test&amp;test日本語&lt;test.

## Headers

Setext Heading
==============

## ATX with closing ##

### Heading Level 3

#### Heading Level 4 ####

##### Heading Level 5 #####

###### Heading Level 6 ######

## Block Quotes

> Quoted apple and apple again.

> Multi-line quote
> with more content
> and **bold** text.

> Nested quote
> > With inner quote
> > and more lines

## Lists

- list apple item
  - nested apple item
  - another nested

- Mixed **bold** and *italic* items
  - [link item](https://test.com)
  - Item with `code`

1. ordered apple item
2. second item
3. third item with **formatting**

- [x] Task apple item
- [ ] Uncompleted task with [link](https://example.com)
- [x] Done task with **bold**

## Tables

| Name | Value | Description |
|:-----|------:|-------------|
| cell apple | 1 | First row |
| test | 999 | With **bold** |
| 日本語 | 2 | Unicode cell |

| Col1 | Col2 |
|------|------|
| [link](https://a.com) | text |
| **bold** | *italic* |

## Code Blocks

```lua
local greeting = "hello"
print(greeting)
local test = "with unicode: 日本語"
```

```javascript
const test = "string with 🎉 emoji";
const url = "https://example.com";
```

```
Plain text code block
with no syntax highlighting
日本語 and emoji 🚀
```

## Line Breaks

Hard break line one  
and line two after the break.

Backslash break line one\
and line two after that break.

## Whitespace and Tabs

Mixed	tab 日本語 and 🎉 emoji here.

Multiple	tabs	between	words	here.

Trailing spaces with content   
next line starts.

## Images and Media

![alt text](./missing-image.png)

![Unicode alt: 日本語](./image.jpg)

![Emoji alt 🎉](./test.svg)

## Inline HTML

<span data-test="true">HTML span element</span>

HTML with [link inside](https://example.com).

<div>
Block HTML with **markdown** inside
</div>

## Complex Mixed Content

**Bold with [link](https://test.com) inside** and *italic with `code` inside*.

> Quote with [link](https://quote.com) and **bold** and `code` mixed.

- List item with **bold** [link](https://list.com) and `code`
  - Nested with 日本語 and 🎉

| Cell | Content |
|------|---------|
| **bold [link](https://table.com)** | test |
| `code` 日本語 | 🎉 |

## Escape Sequences

Escaped \*star\* and \[bracket\] and \(paren\).

Backslash: \\ double backslash.

Mixed: Some \*not bold\* but **this is bold**.

## Reference Links and Definitions

A [reference link][ref] appears here.

Another [reference][ref] to same target.

[Different reference][other] points elsewhere.

All [different][unique] references here.

[ref]: https://example.net/reference
[other]: https://example.com/other
[unique]: https://example.org/unique

## Bare URLs (Auto-link Degradation Test)

Bare URL: http://example.org/bare/path?query=value inside text.

Another: https://example.com/test#anchor at line end.

ftp://ftp.example.com/file.txt in middle.

## Edge Cases for Byte Column Precision

Single char: a

Two byte UTF-8: é

Three byte: 日

Four byte: 🎉

Emoji with ZWJ: 👨‍👩‍👧‍👦 family.

Combining: e̊ (e + combining ring above).

## Tab Character Tests

Before tab	after tab.

Multiple	consecutive	tabs	here.

Tab	日本語	tab	🎉	tab.

List with tab:
- Tab	inside	item
  - Nested	tab	item

## All Elements on One Line

**Bold** and *italic* and `code` and [link](https://test.com) and 日本語 and 🎉 and &amp; all together.

## Final Verification Line

This line tests [exact](https://exact.com) byte **column** precision with 日本語 and 🎉 and multiple [links](https://test.com) mixed together.

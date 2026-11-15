# Third-Party Notices

## Lyric subsystem (2.2.0)

The 2.2.0 lyric subsystem (`Beans/SherryLyricsMatcher.swift`,
`Beans/SherryKugouLyrics.swift`, `Beans/SherryLRCLIB.swift`,
`Beans/SherryLyricsCache.swift`, `Beans/SherryLyricsService.swift`,
`Beans/SherryLyricsSyncEngine.swift`) adapts mechanisms from LyricsIsland
by Praveet Gupta (https://github.com/M-E-L-S/LyricsIsland-driveverse,
commit 55acc772), licensed under the MIT License:

> Copyright (c) 2026 Praveet Gupta
>
> Permission is hereby granted, free of charge, to any person obtaining a copy
> of this software and associated documentation files (the "Software"), to deal
> in the Software without restriction, including without limitation the rights
> to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
> copies of the Software, and to permit persons to whom the Software is
> furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in all
> copies or substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
> IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
> FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
> AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
> LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
> OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
> SOFTWARE.

The KRC decode logic (krc1 magic, fixed 16-byte XOR key, zlib payload) was
informed by Lyricify Lyrics Helper (https://github.com/WXRIW/Lyricify-Lyrics-Helper),
licensed under the Apache License, Version 2.0. A copy of the Apache-2.0
license text is available at https://www.apache.org/licenses/LICENSE-2.0.

Sonar (https://github.com/can4hou6joeng4/Sonar, GPL-3.0) was read for ideas
only (generation guard, next-track prefetch, quality fallback, 429 circuit
breaker, synthesized word-level fallback, extrapolated lyric clock). No Sonar
code was copied into Sherry; all playback-engine changes in 2.2.0 were
written from scratch for this project.

MusicFree (AGPL-3.0) and LX Music mobile (Apache-2.0) were read for flow
shapes only (cache-first lookup, stale-result guards, cross-source fallback);
no code was copied from either project.

## Lyric coverage fixes (2.2.2)

The 2.2.2 lyric-coverage work ports mechanisms from LX Music mobile by
lys whut (https://github.com/lyswhut/lx-music-mobile, snapshot 0669d1b6,
2026-10-30), licensed under the Apache License, Version 2.0:

- Kuwo search (`search.kuwo.cn/r.s`, `src/utils/musicSdk/kw/musicSearch.js`)
  and Kuwo lyric download + decode (`mlyric.kuwo.cn/mobi.s`,
  `src/utils/musicSdk/kw/lyric.js` `getLyric` and `kw/decodeLyric.js`:
  `TP=content` header, zlib inflate, base64, cyclic XOR with the `yeelion`
  key) and the Kuwo word-tag transform (`kw/util.js` `lrcTools`: `[kuwo:N]`
  octal parameter → start/end times) — reimplemented in Swift for Sherry's
  model in `Beans/SherryKuwoLyrics.swift` and `Beans/Models.swift`
  (`LyricWordFormat.kuwo`).
- Kugou backup endpoint `m.kugou.com/app/i/krc.php?cmd=100`
  (`src/utils/musicSdk/kg/lyric.js`, commented-out legacy implementation)
  with the `KG-RC` / `KG-THash` headers — reimplemented in
  `Beans/SherryKugouLyrics.swift` (`backupDocument`).
- Content-validated success (a lyric only counts when its text contains
  timestamped lines, `src/utils/musicSdk/kw/lyric.js` `existTimeExp`),
  per-source isolation with short timeouts, and treating HTTP 200 with
  zero candidates as a transient failure to back off from rather than a
  permanent miss (`src/utils/musicSdk/kg/util.js` `createHttpFetch`).

The Kugou `timelength` (seconds) / `lrctxt=1` parameters and the
`KG-RC` / `KG-THash` headers were A/B-tested against the existing
`duration` (milliseconds) search on 2026-11-16 and showed no difference
in candidate counts, so they were NOT adopted for the main search.

A copy of the Apache-2.0 license text is available at
https://www.apache.org/licenses/LICENSE-2.0.

MusicFree (https://github.com/maotoumao/MusicFree, AGPL-3.0) was read for
ideas only: its cross-source `searchSimilarLyric` (Levenshtein edit-distance
matching as a last resort, `src/core/lyricManager.ts`) informed the
edit-distance fallback in `Beans/SherryKuwoLyrics.swift` (`choose`) and
`Beans/SherryLyricsMatcher.swift` (`editDistance`). No MusicFree code was
copied into Sherry; the distance function is a standard dynamic-programming
implementation written from scratch.

Lyricify (https://github.com/WXRIW/Lyricify-App) is docs-only and
closed-source: no code was borrowed; only the documented
preferred-source / fallback-source strategy was noted.

## Complete CiliCili module (2026-09-25)

`Modules/CiliCili/Sources` is a direct copy of Rone89/cilicili at
`c61b0d33966c5d8e87ea20527b8ba48c702c10c1`, with the integration changes
listed in `Modules/CiliCili/PORTING.md`. This replaces the earlier adapted
Beans Bilibili UI described below. The combined test distribution is provided
under GPL-3.0-only; existing MIT copyright notices remain intact.
See `Modules/CiliCili/LICENSE` and `Beans/Resources/CiliCili-NOTICE.md`.
Matching complete source is uploaded alongside every test IPA as an Actions
artifact. No Release publication is performed.

## Playback page layout

The optional reference playback style is adapted from the Kumone project by missuo.

Source: https://github.com/missuo/kumone

The upstream project includes GNU General Public License v3.0 and GNU Lesser General Public License v3.0 components. The upstream license and copyright notices are retained for the adapted playback-page code.

## Apple Music playback queue and comments interaction

The Apple Music playback queue's in-place presentation, queue controls, and comments-entry interaction are adapted from the iOS player implementation in Moumusic by jiajia2222.

Source: https://github.com/jiajia2222/Moumusic

Reference revision: v1.0.14 (ddfb8f742b56df949c9afb657ae2b9eb72f69c10).

The upstream license and copyright notices remain applicable to the adapted code.

## Search page interaction

The search page's information hierarchy, bottom search entry, platform selector,
and search-history presentation are adapted from the iOS implementation in
Moumusic by jiajia2222.

Source: https://github.com/jiajia2222/Moumusic

Reference revision: v1.0.14 (ddfb8f742b56df949c9afb657ae2b9eb72f69c10).

The upstream copyright and GNU Lesser General Public License version 3.0 notices
remain applicable to the adapted code.

## Local playlist import

The local playlist import flow, including NetEase public-link resolution,
complete track-id expansion, recursive exported-JSON parsing, and the import
sheet interaction, is adapted from the iOS implementation in Moumusic by
jiajia2222.

Source: https://github.com/jiajia2222/Moumusic

Reference revision: v1.0.14 (ddfb8f742b56df949c9afb657ae2b9eb72f69c10).

The upstream copyright and GNU Lesser General Public License version 3.0 notices
remain applicable.

## Record player mode

The record player mode, including its turntable, tonearm, continuous rotation,
compact metadata, transport controls, mini lyrics, and responsive presentation,
is adapted from the iOS player implementation in Moumusic by jiajia2222.

Source: https://github.com/jiajia2222/Moumusic

Reference revision: v1.0.14 (ddfb8f742b56df949c9afb657ae2b9eb72f69c10).

The adapted implementation is distributed under the terms of GNU Lesser General
Public License version 3.0. The upstream copyright and license notices remain
applicable.

## Duo dynamic glass effect

The optional device-tilt glass fold effect is adapted from DuoLikeAnimation by
Elijah Semyonov.

Source: https://github.com/elijah-semyonov/DuoLikeAnimation

Reference revision: 0aa525639a494be8abdf4c4e1e25dcb52d372d94.

MIT License

Copyright (c) 2026 Elijah Semyonov

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Dynamic wallpaper shaders

The optional Fractal Clouds, Ink Smoke, Liquid Chrome, Neuro Noise, Simplex
Noise, Metaballs, and Water animated wallpaper renderers are adapted from the
ShipSwift project by SignerLabs.

Source: https://github.com/signerlabs/ShipSwift

MIT License

Copyright (c) 2026 SignerLabs

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Bilibili video and live-detail surfaces

The Bilibili video and live-detail surfaces are adapted from the public layout
and interaction structure of these GPL-3.0 projects:

- CiliCili, by Rone89: https://github.com/Rone89/cilicili
- PiliPlus, by bggRGjQaUbCoE: https://github.com/bggRGjQaUbCoE/PiliPlus

The adapted Swift source files are marked with comments. The upstream GPL-3.0
terms and copyright notices apply to the adapted code. The full license text
is available in each upstream repository's `LICENSE` file.

Reference revision used for the CiliCili-derived detail-page structure:
`c61b0d33966c5d8e87ea20527b8ba48c702c10c1` (2026-09-15).

The 2026-09-25 Beans adaptation uses the upstream `VideoDetailView`,
`VideoDetailViewContentResolver`, `VideoDetailNativeContentTabView`,
`UIKitShell/VideoDetailShellContentView`, `CommentsSectionView`,
`CommentsSectionHeader`, `CommentsSectionContentStateView`, `CommentRow`,
`CommentRowHeader`, `CommentRowLayout` and `DynamicCommentFullRowReplyTarget`.
The upstream player surface, action strip, page menu and related list were also
read to guide the integration with Beans' existing AVPlayer and API models.

Adapted files: `Beans/BilibiliVideoPage.swift`,
`Beans/BilibiliNativeComments.swift`, and `Beans/BilibiliCommentRow.swift`.
Changes include stable mounted tabs, a fixed player viewport, scoped comment
refresh/presentation, and independent author/like/media/reply targets.
Copyright notices and GPL-3.0 terms of CiliCili and its contributors remain
applicable. These adapted portions are not relicensed under the root MIT notice.
The full upstream GPL-3.0 text is retained verbatim in
`Beans/Resources/CiliCili-LICENSE.txt`, with attribution and source retrieval
information in `Beans/Resources/CiliCili-NOTICE.md`; both are included in the IPA.


## Borrowed mechanisms (2.2.3)

The 2.2.3 lyric work documents four more projects whose mechanisms were
read while diagnosing the 2.2.2 word-tag leak and the lyric-cache design.
No GPL/AGPL/LGPL code was copied — those projects contributed ideas only,
rewritten from scratch for Sherry's model; the MIT project below was used
for mechanisms, with attribution.

### YesPlayMusic (MIT)

YesPlayMusic by qier222 (https://github.com/qier222/YesPlayMusic),
Copyright (c) 2020-2023 qier222, licensed under the MIT License:

> MIT License
>
> Copyright (c) 2020-2023 qier222
>
> Permission is hereby granted, free of charge, to any person obtaining a copy
> of this software and associated documentation files (the "Software"), to deal
> in the Software without restriction, including without limitation the rights
> to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
> copies of the Software, and to permit persons to whom the Software is
> furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in all
> copies or substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
> IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
> FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
> AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
> LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
> OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
> SOFTWARE.

Mechanisms noted: binary-search lyric parse (`src/utils/lyrics.js`,
`binarySearch` — locate the current line by time instead of scanning the
whole list) and stale-while-revalidate lyric caching (serve the cached
lyric at once, refresh in the background). Sherry's cache-first lookup and
its time-indexed line search follow the same shapes; the implementations
are Sherry's own.

### Kumone (LGPL-3.0-only)

Kumone by missuo (https://github.com/missuo/kumone), licensed under the
GNU Lesser General Public License v3.0 only. Mechanisms noted (ideas only,
no code copied): the text-rebuilt-from-words invariant (the rendered line
text is always rebuilt from the parsed words,
`Sources/Kumone/Core/Models/LyricsParser.swift`), `spreadWords` synthesis
(plain lines spread across their time window into per-word timings), and
audio-clock-anchored karaoke (word highlighting driven by the audio clock,
not wall-clock extrapolation). Sherry 2.2.3 applies the same invariants in
`Beans/Models.swift` (`LyricParser`): `line.text` is built only from parsed
words, and the 2.2.1 audio-clock anchoring is kept.

### RiPlay (GPL-3.0)

RiPlay by fast4x (https://github.com/fast4x/RiPlay), licensed under the
GNU General Public License v3.0. Ideas only, no code copied: the
`plainText` invariant (a tag-free plain-text copy is always kept next to
the timed text, `androidApp/src/main/kotlin/it/fast4x/riplay/extensions/lyricshelper/parsers/LyricsParser.kt`),
duration-from-next-word (a word with no explicit end runs until the next
word starts), Kugou hash-first lookup with a tolerance ramp, and header
normalisation. Sherry 2.2.3 mirrors the plainText invariant in its cache
shape (`rawLRC` is the stripped plain text, `rawKRC` the tagged original).

### Spotube (AGPL-3.0)

Spotube (https://github.com/KRTirtho/spotube), licensed under the GNU
Affero General Public License v3.0. Ideas only, no code copied: tolerant
LRCLIB parsing (accept the many shapes LRCLIB returns instead of failing
the whole document), distinctUntilChanged line updates (only re-render the
lyric line when the active line actually changes), and an explicit quality
table (quality tiers listed as data, not buried in conditionals). Sherry's
LRCLIB fallback and its 4-tier quality menu follow the same shapes.

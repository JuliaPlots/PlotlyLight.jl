# Compression

A plot's data is written into the page as JSON, inside the `<script>` that draws the plot.  That's simple and works everywhere, but numbers are expensive as text: a full-precision `Float64` such as `0.12345678901234568` takes 19 characters.  For large data, wrap an array in `TypedArray` or `Compressed`:

```julia
p = plot.scatter(x = TypedArray(1:10_000), y = Compressed(randn(10_000)))
```

| | Sent as | The browser gets | Works in |
|---|---|---|---|
| (no wrapper) | JSON text | JS arrays of numbers | Everywhere |
| `TypedArray(x)` | Base64 binary, in the smallest type that holds every value | `Uint8Array`, `Float32Array`, … (decoded by plotly.js) | Everywhere plotly.js does |
| `Compressed(x)` | zlib-compressed binary (numeric arrays) or JSON (anything else), base64-encoded | `Uint8Array`, `Float32Array`, … (numeric arrays), or JS values | Browsers with [`DecompressionStream`](https://developer.mozilla.org/en-US/docs/Web/API/DecompressionStream): Chrome 80, Firefox 113, Safari 16.4 |

Values are never changed, unless you give a tolerance (see below).

## `TypedArray`

`TypedArray` uses plotly.js's own format for binary data, so plotly.js decodes it without any extra code.  The pipeline:

```
Julia                                                                           Browser
array ─▶ smallest type ─▶ row-major bytes ─▶ base64 ─▶ {"bdata", "dtype", "shape"} ─▶ plotly.js decodes ─▶ Float32Array, …
```

1. **Smallest type.** Integers use the first of `UInt8`, `Int8`, `UInt16`, `Int16`, `UInt32`, `Int32` that holds every value.  Other numbers (and integers too big for `Int32`) use `Float32` if every value is exactly a `Float32`, otherwise `Float64`.  plotly.js has no `Float16` or `Int64`.
2. **Row-major bytes.** Julia stores matrices column by column, and plotly.js reads them row by row, so the bytes are reordered.
3. **Base64**, so the bytes can go in the page as text.
4. **A plotly.js "typed array spec"**: e.g. `{"bdata":"AADAPwAAAEA=","dtype":"float32","shape":"2"}`.  `shape` is `"rows,columns"` for a matrix.

To allow `Float32` when it's close enough, give a relative or absolute tolerance: `TypedArray(y, 1e-5)` or `TypedArray(y, 0.0, 1e-3)`.  Arrays that plotly.js can't decode as typed arrays (`Bool`s, non-numbers, `missing`s, empty arrays, or more than 3 dimensions) are written as JSON.  `PlotlyLight.typed_array(x; rtol=0.0, atol=0.0)` returns the `(; bdata, dtype, shape)` that is written for `x`.

## `Compressed`

`Compressed` shrinks the data with zlib, and the browser decompresses it while drawing the plot.  It has two pipelines.

**Numeric arrays** become JavaScript typed arrays:

```
Julia:    array ─▶ element type ─▶ row-major bytes ─▶ zlib ─▶ base64
Browser:  base64 ─▶ bytes ─▶ DecompressionStream("deflate") ─▶ ArrayBuffer ─▶ Float64Array, … ─▶ rows (matrices, 3-d arrays)
```

1. **Element type.** An array keeps its element type if JavaScript has an array of it (`UInt8`, `Int8`, `UInt16`, `Int16`, `UInt32`, `Int32`, `Float16`, `Float32`, `Float64`), so you choose the size: e.g. `Compressed(Float32.(y))`.  Other element types (e.g. `Int64`) are converted to the smallest type above that holds every value exactly.
2. **Row-major bytes**, as for `TypedArray`.
3. **zlib**, at `Compressed(x; level)` from `0` (no compression) to `9` (smallest, and slowest).  The default is `6`.  The browser reads this format with `DecompressionStream("deflate")`.
4. **Base64.**
5. In the browser, the bytes are decompressed into an `ArrayBuffer` and wrapped in the matching typed array (`Float64Array`, …).  A matrix becomes an array of rows, and a 3-d array an array of arrays of rows, as plotly.js reads them.  The rows are views of the same buffer, not copies.

**Numbers with gaps** (arrays whose elements can be `missing` or `nothing`, e.g. `Vector{Union{Missing, Float64}}`) go through the same pipeline as numeric arrays, with `NaN` in each gap, which plotly.js treats like JSON's `null` (e.g. a break in a line, or an empty heatmap cell).  To hold `NaN`, they're always floats: a `Float32Array` if every other value is a `Float32` (within the tolerances), otherwise a `Float64Array`.  With 10% `missing`s, a million `Float64`s came to 52% of the JSON's size, compared with 61% when compressed as JSON.

**`Bool` arrays** become JavaScript arrays of `true`/`false` (not 0s and 1s, which plotly.js treats differently):

```
Julia:    array ─▶ row-major bytes (one per value: 0 or 1) ─▶ zlib ─▶ base64
Browser:  base64 ─▶ bytes ─▶ DecompressionStream("deflate") ─▶ Uint8Array ─▶ Array of true/false ─▶ rows (matrices, 3-d arrays)
```

zlib shrinks the 0s and 1s to about 1.3 bits per value for random data (less for runs of the same value), compared with 5.5 characters each as JSON.  `BitArray`s work too.

**Everything else** (strings, `Config`s, arrays of only `missing`s, `Bool`s with gaps, …) is compressed as JSON:

```
Julia:    value ─▶ JSON text ─▶ zlib ─▶ base64
Browser:  base64 ─▶ bytes ─▶ DecompressionStream("deflate") ─▶ Response.json() ─▶ JS value
```

In both cases, what's written into the page is a JavaScript expression, not JSON.  For `Compressed([1.5 2.5; 3.5 4.5])`, it's:

```js
(await (async b => {
    const x = new Float64Array(await new Response(new Blob([Uint8Array.fromBase64?.(b) ?? Uint8Array.from(atob(b), c => c.charCodeAt(0))])
        .stream().pipeThrough(new DecompressionStream("deflate"))).arrayBuffer());
    const rows = (x, dims) => Array.from({length: dims[0]}, (_, i) => {
        const n = x.length / dims[0], row = x.subarray(i * n, (i + 1) * n);
        return dims.length == 2 ? row : rows(row, dims.slice(1));
    });
    return rows(x, [2,2]);
})("eJxjYACBH/ZgioHFAULzQGkhBwAnGwIa"))
```

The expression uses `await`.  That works because PlotlyLight draws each plot in an `async` script, but it means `Compressed` data isn't valid JSON anywhere else, e.g. in files you pass to other tools such as PlotlyKaleido.  `Uint8Array.fromBase64` is used where the browser has it (Chrome 140, Firefox 133, Safari 18.2), and `atob` otherwise.  `Float16Array` needs Chrome 135, Firefox 129, or Safari 18.2.

## Compressing every plot

To compress the data of every plot you display (or save as an image), without wrapping each array yourself, use `preset.compression`:

```julia
preset.compression.on!()                          # level=6, rtol=0.0, atol=0.0, n=1000
preset.compression.on!(level=1, rtol=1e-5, n=100) # any of the keywords below
preset.compression.off!()                         # back to the default: off
```

- `level`: zlib compression level, from `1` (fastest) to `9` (smallest).  `0` turns this off.
- `n`: arrays in a plot's traces with at least `n` elements, including nested ones such as `marker.color`, are sent as `Compressed`.  Smaller arrays stay JSON.
- `rtol`, `atol`: numeric arrays are converted to the smallest type that holds every value within these tolerances (as for `TypedArray`), e.g. `Float64` data becomes `Float32` where that changes no value by more than `rtol`.  The same tolerances apply when `Compressed(x)` converts a type that JavaScript has no array of, such as `Int64`, and when it picks `Float32` or `Float64` for numbers with gaps.

The plot itself isn't changed: arrays are only replaced in the copy that's written into the page.

The presets set `PlotlyLight.settings.compression`, a `(; level, rtol, atol, n)` named tuple, which you can also set directly.

## Which to use

Sizes on a million values, as a percentage of the JSON's size (both wrappers include base64's extra third):

| Data | `TypedArray` | `Compressed` | `Compressed(Float32.(x))` |
|---|---|---|---|
| `randn(10^6)` | 54% | 52% | 25% |
| `sin.(0:1e-5:10)` | 55% | 42% | 17% |
| `rand(1:100, 10^6)` | 46% | 38% | 61% |
| `1:10^6` | 77% | 27% | 19% |
| `round.(randn(10^6), digits=2)` | 198% | 47% | 44% |
| `repeat([1.5, 2.5], 10^5)` | 133% | 0.6% | 0.2% |

- `Compressed` is usually the smaller.  Compressing took up to about half a second per million values at the default level.
- `TypedArray` can be larger than JSON for short decimals such as rounded data: `0.12` is 4 characters of JSON, but 8 bytes as a `Float64`.
- Noisy floats barely compress, so for them the two are about the same size.  Converting to `Float32` halves them again or better, but rounds each value to about 7 significant digits.
- Integers: `Compressed` converts `Int64`s to the smallest type that holds them (`UInt8` for `rand(1:100, 10^6)`), so don't convert them to `Float32` yourself.

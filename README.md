# TeeStreams

Simplify writing to multiple streams at once.

## Usage

```julia
tee = TeeStream(io::IO...)
```

Construct a tee stream by wrapping multiple writable IO objects.

```julia
TeeStream(f::Function, io::IO...) do tee
    # ...
end
```

Construct a tee stream by wrapping multiple writable IO objects and
call function `f` on the tee. Automatically calls `close` on the tee
before returning.

`close` and `flush` on a tee stream closes/flushes all the wrapped streams.

### Example: Compress with multiple encodings

```julia
using TeeStreams, CodecZlib, CodecZstd

function compress(file)
    open(file, "r") do src
        TeeStream(
            GzipCompressorStream(open(file * ".gz", "w")),
            ZstdCompressorStream(open(file * ".zst", "w"))
            ) do tee
            write(tee, src)
        end
    end
end

compress("Project.toml")
```

### Example: Write data to checksum function and to disk

```julia
using TeeStreams, SHA, SimpleBufferStream

function download_verify(url, expected_shasum)
    filename = split(url, '/')[end]
    buf = BufferStream()
    @sync begin
        @async begin
            TeeStream(buf, open(filename, "w")) do tee
                write(tee, open(`curl -fsSL $url`))
            end
        end
        @async begin
            shasum = bytes2hex(SHA.sha256(buf))
            if shasum != expected_shasum
                error("something went wrong")
            end
        end
    end
end

url = "https://julialang-s3.julialang.org/bin/linux/x64/1.5/julia-1.5.3-linux-x86_64.tar.gz"
expected_shasum = "f190c938dd6fed97021953240523c9db448ec0a6760b574afd4e9924ab5615f1"

download_verify(url, expected_shasum)
```

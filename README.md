# TeeStreams

Simplify writing to multiple streams at once.

### Example: Compress with multiple encodings

```julia
using TeeStreams, CodecZlib, CodecZstd

function compress(file)
    open(file, "r") do src
        teeopen(tee -> write(tee, src),
            (GzipCompressorStream, file * ".gz", "w"),
            (ZstdCompressorStream, file * ".zst", "w")
        )
    end
end

compress("Project.toml")
```

### Example: Pass data to checksum function and to disk

```julia
using TeeStreams, SHA, SimpleBufferStream

function download_verify(url, expected_shasum)
    filename = split(url, '/')[end]
    buf = BufferStream()
    dl_task = @async begin
        teeopen(buf, (filename, "w")) do tee
            write(tee, open(`curl -fsSL $url`))
        end
    end
    shasum = fetch(@async bytes2hex(SHA.sha256(buf)))
    if shasum != expected_shasum
        error("something went wrong")
    end
    wait(dl_task)
end

url = "https://julialang-s3.julialang.org/bin/linux/x64/1.5/julia-1.5.3-linux-x86_64.tar.gz"
expected_shasum = "f190c938dd6fed97021953240523c9db448ec0a6760b574afd4e9924ab5615f1"

download_verify(url, expected_shasum)
```

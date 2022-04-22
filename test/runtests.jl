# SPDX-License-Identifier: MIT

using TeeStreams, Test, SimpleBufferStream, HTTP,
      CodecZlib, CodecZstd, SHA, Tar


function write_things(io)
    # String
    write(io, "hello, string\n")
    # Single byte and byte arrays
    for b in Vector{UInt8}("hello, ")
        write(io, b)
    end
    write(io, Vector{UInt8}("bytes\n"))
    # Write from file (IOStream)
    f, s = mktemp()
    write(s, "hello, file\n"); close(s)
    open(io1 -> write(io, io1), f)
    # Read from external process (Base.Process)
    open(`$(Base.julia_cmd()[1]) -e 'println("hello, process")'`) do proc
        write(io, proc)
    end
    # print(ln)
    print(io, "hello, "); println(io, "print")
    return io
end

@testset "TeeStreams" begin
    # write(::TeeStream, x) for different x and tee'd streams

    correct = String(take!(write_things(IOBuffer())))

    # tee = TeeStream(...)
    iob = IOBuffer()
    ioc = IOContext(IOBuffer())
    f, iof = mktemp()
    bs = BufferStream()
    tee = TeeStream(iob, ioc, iof, bs)
    write_things(tee)
    flush(tee)
    close(iof); close(bs)
    @test String(take!(iob)) == String(take!(ioc.io)) ==
          read(f, String) == read(bs, String) == correct
    close(tee)
    try
        write_things(tee)
    catch err
        @test err isa CompositeException
        @test length(err.exceptions) == 4
        @test all(x -> x isa TaskFailedException, err.exceptions)
    end

    # TeeStream(...) do tee
    mktempdir() do tmpd;
        f1 = joinpath(tmpd, "file")
        io1 = open(f1, "w")
        f2 = joinpath(tmpd, "file2")
        io2 = open(f2, "w")
        @test isopen(io1)
        @test isopen(io2)
        TeeStream(io1, io2) do tee
            write_things(tee)
            flush(tee)
        end
        @test !isopen(io1)
        @test !isopen(io2)
        @test read(f1, String) == read(f2, String) == correct
    end

    # Redirection of std(out|err) to TeeStream
    io = IOBuffer()
    ioc = IOContext(IOBuffer())
    tee = TeeStream(io, ioc)
    ret1, ret2 = redirect_stderr(tee) do
        r1 = redirect_stdout(tee) do
            print(stderr, "stderr")
            print(stdout, "stdout")
            return 1
        end
        return r1, 2
    end
    @test ret1 == 1
    @test ret2 == 2
    @test String(take!(io)) == String(take!(ioc.io)) == "stderrstdout"

    # Test some integration with other packages
    mktempdir() do tmpd
        url = "https://julialang-s3.julialang.org/bin/linux/x64/1.5/julia-1.5.3-linux-x86_64.tar.gz"
        expected_shasum = "f190c938dd6fed97021953240523c9db448ec0a6760b574afd4e9924ab5615f1"

        #          HTTP.Stream
        #               +
        #               |
        #      +--------+----------+
        #      |                   |
        #      v                   v
        # BufferStream      GzipDecompressor
        #      +                   +
        #      |                   |
        #      v                   v
        # SHA.sha256          BufferStream
        #                          +
        #                          |
        #                          v
        #                     Tar.rewrite
        #                          +
        #                          |
        #                 +--------+---------+
        #                 |                  |
        #                 v                  v
        #            GzipCompressor   ZstdCompressor

        buffer_shasum = BufferStream()
        buffer_tar = BufferStream()
        decompressor = GzipDecompressorStream(buffer_tar)
        tee = TeeStream(buffer_shasum, decompressor)
        compressors = TeeStream(
            GzipCompressorStream(open(joinpath(tmpd, "julia.tar.gz"), "w")),
            ZstdCompressorStream(open(joinpath(tmpd, "julia.tar.zst"), "w")),
        )
        @sync begin
            dl_task = @async (HTTP.get(url; response_stream=tee); close(tee))
            sha_task = @async bytes2hex(SHA.sha256(buffer_shasum))
            tar_task = @async Tar.rewrite(buffer_tar, compressors)
            @test fetch(sha_task) == expected_shasum
        end
    end

end #testset

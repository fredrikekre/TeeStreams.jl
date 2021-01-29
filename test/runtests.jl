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
    write(io, open(`$(Base.julia_cmd()[1]) -e 'println("hello, process")'`))
    # print(ln)
    print(io, "hello, "); println(io, "print")
    return io
end

@testset "TeeStreams" begin
    correct = String(take!(write_things(IOBuffer())))

    # write(::TeeStream, x) for different x and tee'd streams
    iob = IOBuffer()
    ioc = IOContext(IOBuffer())
    f, iof = mktemp()
    bs = BufferStream()
    tee = TeeStream(iob, ioc, iof, bs)
    write_things(tee)
    close(iof); close(bs)
    @test String(take!(iob)) == String(take!(ioc.io)) ==
          read(f, String) == read(bs, String) == correct
    try
        close(tee)
        write_things(tee)
    catch err
        @test err isa CompositeException
        @test length(err.exceptions) == 4
        @test all(x -> x isa TaskFailedException, err.exceptions)
    end

    mktempdir() do tmpd; f = joinpath(tmpd, "file")
        # tee = teeopen()
        ## with teeclose
        iob = IOBuffer()
        ioc = IOContext(IOBuffer())
        tee = teeopen(iob, ioc, (f, "w"))
        write_things(tee)
        teeclose(tee)
        @test String(take!(iob)) == String(take!(ioc.io)) == read(f, String) == correct
        ## with close
        iob = IOBuffer()
        ioc = IOContext(IOBuffer())
        tee = teeopen(iob, ioc, (f, "w"))
        write_things(tee)
        close(tee)
        @test_throws ArgumentError String(take!(iob))
        @test_throws ArgumentError String(take!(ioc.io))
        @test read(f, String) == correct

        # teeopen() do tee
        iob = IOBuffer()
        ioc = IOContext(IOBuffer())
        teeopen(iob, ioc, (f, "w")) do tee
            write_things(tee)
        end
        @test_throws ArgumentError String(take!(iob))
        @test_throws ArgumentError String(take!(ioc.io))
        @test read(f, String) == correct
    end

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

        tee = teeopen(
            (GzipCompressorStream, joinpath(tmpd, "julia.tar.gz"), "w"),
            (ZstdCompressorStream, joinpath(tmpd, "julia.tar.zst"), "w"),
        )
        bs = BufferStream()
        bs2 = BufferStream()
        gzd = GzipDecompressorStream(bs2)
        tee2 = teeopen(bs, gzd)
        @sync begin
            tar_task = @async Tar.rewrite(bs2, tee)
            dl_task = @async HTTP.get(url; response_stream=tee2)
            sha_task = @async bytes2hex(SHA.sha256(bs))
            @test fetch(sha_task) == expected_shasum
        end
    end

end #testset

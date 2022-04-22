# SPDX-License-Identifier: MIT

module TeeStreams

export TeeStream
"""
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
"""
struct TeeStream{T <: NTuple{<:Any, IO}} <: IO
    streams::T
    opened_idx::Union{<:NTuple{<:Any,Bool}, Nothing}
    function TeeStream{T}(ios::T, opened_idx=nothing) where T <: NTuple{<:Any, IO}
        tee = new{T}(ios, opened_idx)
        # check_writable(tee)
        return tee
    end
end

TeeStream(ios::IO...) = TeeStream{typeof(ios)}(ios)
function TeeStream(f::Function, ios::IO...)
    tee = TeeStream(ios...)
    try
        f(tee)
    finally
        close(tee)
    end
end

# See https://docs.julialang.org/en/v1/base/io-network/#Base.unsafe_write
function Base.unsafe_write(tee::TeeStream, p::Ptr{UInt8}, nb::UInt)
    @sync for s in tee.streams
        @async begin
            # TODO: Is it enough to rely on write locks on each s?
            n = unsafe_write(s, p, nb)
            check_written(n, nb)
        end
    end
    return Int(nb)
end
function Base.write(tee::TeeStream, b::UInt8)
    # check_writable(tee)
    for s in tee.streams
        n = write(s, b)
        check_written(n, 1)
    end
    return 1
end

"""
    close(tee::TeeStream)

Close all streams wrapped in the tee stream.
"""
Base.close(tee::TeeStream) = foreach(close, tee.streams)

"""
    flush(tee::TeeStream)

Flush all streams wrapped in the tee stream.
"""
Base.flush(tee::TeeStream) = foreach(flush, tee.streams)

Base.isreadable(tee::TeeStream) = false
Base.isopen(tee::TeeStream) = all(isopen, tee.streams)
Base.iswritable(tee::TeeStream) = all(iswritable, tee.streams)

# All streams do not define iswritable reliably so just try and throw if things doesn't work
# function check_writable(tee::TeeStream)
#     if !(isopen(tee) && iswritable(tee))
#         error("stream is closed or not writeable")
#     end
# end
function check_written(n, m)
    if n != m
        error("could not write the requested bytes: stream is closed or not writeable?")
    end
    return nothing
end


# maybe_open(io) = io
# maybe_open(io::Tuple) = open(io...)
# function teeopen(args::Union{IO, Tuple}...)
#     opened_idx = ntuple(i -> args[i] isa Tuple, length(args))
#     streams = map(maybe_open, args)
#     return TeeStream{typeof(streams)}(streams, opened_idx)
# end

# function teeopen(f::Function, args::Union{IO,Tuple}...)
#     tee = teeopen(args...)
#     try
#         f(tee)
#     finally
#         close(tee)
#         # teeclose(tee)
#     end
# end

# function teeclose(tee::TeeStream)
#     if tee.opened_idx === nothing
#         return
#     end
#     for i in 1:length(tee.streams)
#         tee.opened_idx[i] || continue
#         close(tee.streams[i])
#     end
# end

# Adapted from Logging2.jl (MIT License: Copyright (c) 2020 Chris Foster)
# https://github.com/JuliaLogging/Logging2.jl/blob/094eb6619aeaa8815585dbe7f33b4972f9a4ce6b/src/Logging2.jl#L12-L37
function (redirect_func::Base.RedirectStdStream)(f::Function, io::TeeStream)
    prev_stream =
        redirect_func.unix_fd == 1 ? stdout :
        redirect_func.unix_fd == 2 ? stderr :
        throw(ArgumentError("Can only redirect stdout and stderr to TeeStream."))

    result = nothing

    rd, rw = redirect_func()
    try
        @sync begin
            try
                Threads.@spawn write(io, rd) # loops while !eof(rd)
                result = f()
            finally
                # To close the read side of the pipe, we must close *all*
                # writers. This includes `rw`, but *also* the dup'd fd
                # created behind the scenes by redirect_func(). (To close
                # that, must call redirect_func() here with the prev stream.)
                close(rw)
                redirect_func(prev_stream)
            end
        end
    finally
        close(rd)
    end
    return result
end


end # module


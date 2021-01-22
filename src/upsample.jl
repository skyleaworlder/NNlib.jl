export upsample_bilinear, ∇upsample_bilinear, pixel_shuffle

# utility function
@inline function compute_source_index_and_lambda(
    ratio, # 0 < ratio < 1
    output_index,
    input_size,
    output_size
)
    real_input_index = ratio*output_index
    input_index0 = floor(Int, real_input_index) # typecast to int was here in C++
    offset = (input_index0 < input_size - 1) ? 1 : 0
    input_index1 = input_index0 + offset
    lambda1 = real_input_index - input_index0
    lambda0 = 1 - lambda1
    return input_index0, input_index1, lambda0, lambda1
end

"""
    upsample_bilinear(x::AbstractArray{T,4}, scale::NTuple{2,Real}=(1,1); size::Union{Nothing,NTuple{2,Integer}}=nothing)

Upsamples the first 2 dimensions of the array `x` by the upsample factors stored in `scale`,
using bilinear interpolation.

The size of the output is equal to
`(scale[1]*S1, scale[2]*S2, S3, S4)`, where `S1, S2, S3, S4 = size(x)`.

Examples:
```julia
upsample_bilinear(x, (2, pi)) # real scaling factors are allowed
upsample_bilinear(x; size=(64,64)) # note the semicolon, size is a keyword argument
```
Currently only 2d upsampling is supported.
"""
function upsample_bilinear(x::AbstractArray{T,4}, scale::NTuple{2,Real}=(1,1); size::Union{Nothing,NTuple{2,Integer}}=nothing) where T
    w,h,c,n = Base.Base.size(x)
    if scale != (1,1) && size !== nothing
        error("Please provide either scale or size, not both. Got scale=$scale and size=$size.")
    end
    if size === nothing
        out_w = floor(Int, scale[1]*w)
        out_h = floor(Int, scale[2]*h)
    else
        out_w, out_h = size
    end
    y = Array{T,4}(undef, out_w, out_h, c, n)
    return upsample_bilinear_whcn!(y, x)
end

upsample_bilinear(x, scale::Real; size=nothing) = upsample_bilinear(x, (scale,scale); size=size)

function upsample_bilinear(x::AbstractArray{T,4}, scale::NTuple{2,Real}=(1,1); size=nothing) where T<:Integer
    y = float.(x)
    res = upsample_bilinear(y, scale; size=size)
    return round.(T, res)
end

# this is the core function which works on arrays of arbitrary size
# the implementation is a translation of https://github.com/pytorch/pytorch/blob/master/aten/src/ATen/native/cpu/UpSampleMoreKernel.cpp
# which implements open-cv style linear interpolation / upsampling
# for simplicity, corners are aligned and all logic for other behaviour has been stripped
# - whcn because there is also a cwhn implementation
# - the function is parallelized using @threads
# - RGB types could be supported via reinterpreting
# - integer types need to be converted to Float and back
# - rationals work, but are slow
function upsample_bilinear_whcn!(output::AbstractArray{T,4}, input::AbstractArray{T,4}) where T
    if size(input) == size(output)
        return input
    end
    size(input)[3:4] == size(output)[3:4] || error("Number of input and output channels and batches must match. Got input $(size(input)) and output $(size(output))")
    in_w, in_h, channels, batches = size(input)
    # treat batch and channel dimension as one for better parallelization granularity
    channels *= batches
    out_w, out_h, _, _ = size(output)
    output_slice_size = out_h * out_w

    # T() and // so that we can handle rationals (super slow)
    width_scale  = T((in_w - 1) // (out_w - 1))
    height_scale = T((in_h - 1) // (out_h - 1))

    @inline idx(c, h, w) = c * in_h * in_w + h * in_w + w + 1

    @inbounds Threads.@threads for c in 0:channels-1
        for oh in 0:out_h-1
            ih0, ih1, h0lambda, h1lambda = compute_source_index_and_lambda(height_scale, oh, in_h, out_h)
            for ow in 0:out_w-1
                iw0, iw1, w0lambda, w1lambda = compute_source_index_and_lambda(width_scale, ow, in_w, out_w)
                output_offset = c * output_slice_size + oh * out_w + ow + 1
                output[output_offset] =
                    (h0lambda * w0lambda * input[idx(c, ih0, iw0)] + # h0 * w0 * i00
                     h0lambda * w1lambda * input[idx(c, ih0, iw1)] + # h0 * w1 * i01
                     h1lambda * w0lambda * input[idx(c, ih1, iw0)] + # h1 * w0 * i10
                     h1lambda * w1lambda * input[idx(c, ih1, iw1)])  # h1 * w1 * i11
            end
        end
    end
    return output
end

"""
    ∇upsample_bilinear(Δ::AbstractArray{T,4}, scale::NTuple{2,Real}=(1,1); size::Union{Nothing,NTuple{2,Integer}}=nothing) where T

# Arguments
- `Δ`: incoming gradient array that has been upsampled using the upsample factors in `scale`

# Outputs
- `dx`: downsampled version of `Δ`
"""
function ∇upsample_bilinear(Δ::AbstractArray{T,4}, scale::NTuple{2,Real}=(1,1); size::Union{Nothing,NTuple{2,Integer}}=nothing) where T
    w,h,c,n = Base.size(Δ)
    if scale != (1,1) && size !== nothing
        error("Please provide either scale or size, not both. Got scale=$scale and size=$size.")
    end
    if size===nothing
        out_w = ceil(Int, w/scale[1])
        out_h = ceil(Int, h/scale[2])
    else
        out_w, out_h = size
    end
    dx = zeros(T, out_w, out_h, c, n)
    return ∇upsample_bilinear_whcn!(Δ, dx)
end

∇upsample_bilinear(Δ, scale::Real; size=nothing) = ∇upsample_bilinear(Δ, (scale, scale); size=size)

function ∇upsample_bilinear_whcn!(Δ::AbstractArray{T,4}, grad_input::AbstractArray{T,4}) where T
    size(grad_input)[3:4] == size(Δ)[3:4] || error("Number of input and output channels and batches must match. Got input $(size(input)) and output $(size(output))")
    in_w, in_h, channels, batches = size(grad_input)

    # treat batch and channel dimension as one for better parallelization granularity
    channels *= batches
    out_w, out_h, _, _ = size(Δ)
    output_slice_size = out_h * out_w

    width_scale  = T((in_w - 1) // (out_w - 1))
    height_scale = T((in_h - 1) // (out_h - 1))

    @inline idx(c, h, w) = c * in_h * in_w + h * in_w + w + 1

    @inbounds Threads.@threads for c in 0:channels-1
        for oh in 0:out_h-1
            ih0, ih1, h0lambda, h1lambda = compute_source_index_and_lambda(height_scale, oh, in_h, out_h)
            for ow in 0:out_w-1
                iw0, iw1, w0lambda, w1lambda = compute_source_index_and_lambda(width_scale, ow, in_w, out_w)
                output_offset = c * output_slice_size + oh * out_w + ow + 1
                Δ_value = Δ[output_offset]
                grad_input[idx(c, ih0, iw0)] += h0lambda * w0lambda * Δ_value # i00
                grad_input[idx(c, ih0, iw1)] += h0lambda * w1lambda * Δ_value # i01
                grad_input[idx(c, ih1, iw0)] += h1lambda * w0lambda * Δ_value # i10
                grad_input[idx(c, ih1, iw1)] += h1lambda * w1lambda * Δ_value # i11
            end
        end
    end
    return grad_input
end

function ChainRulesCore.rrule(::typeof(upsample_bilinear), x, scale; size=nothing)
    Ω = upsample_bilinear(x, scale; size=size)
    function upsample_bilinear_pullback(Δ)
        (NO_FIELDS, ∇upsample_bilinear(Δ, scale; size=(Base.size(x,1),Base.size(x,2))), DoesNotExist())
    end
    return Ω, upsample_bilinear_pullback
end

"""
    pixel_shuffle(x, r)

Pixel shuffling operation. `r` is the upscale factor for shuffling.
The operation converts an input of size [W,H,r²C,N] to size [rW,rH,C,N]
Used extensively in super-resolution networks to upsample
towards high resolution features.

Reference : https://arxiv.org/pdf/1609.05158.pdf
"""
function pixel_shuffle(x::AbstractArray, r::Integer)
    @assert ndims(x) > 2
    d = ndims(x) - 2
    sizein = size(x)[1:d]
    cin, n = size(x, d+1), size(x, d+2)
    @assert cin % r^d == 0
    cout = cin ÷ r^d
    # x = reshape(x, sizein..., fill(r, d)..., cout, n) # bug https://github.com/FluxML/Zygote.jl/issues/866
    x = reshape(x, sizein..., ntuple(i->r, d)..., cout, n)
    perm = [d+1:2d 1:d]' |> vec  # = [d+1, 1, d+2, 2, ..., 2d, d]
    x = permutedims(x, (perm..., 2d+1, 2d+2))
    return reshape(x, ((r .* sizein)..., cout, n))
end

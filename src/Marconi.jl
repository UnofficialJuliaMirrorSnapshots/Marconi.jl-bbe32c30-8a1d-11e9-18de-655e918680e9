module Marconi

import Base.show
import Base.==
import Base.findmax
using LinearAlgebra
using Interpolations
using Printf
using CSV

# Package exports
export readTouchstone
export writeTouchstone
export isPassive
export isReciprocal
export AbstractNetwork
export AbstractRadiatonPattern
export DataNetwork
export EquationNetwork
export testDelta
export testMagDelta
export testK
export testMUG
export testMSG
export testMAG
export ∠
export inputZ
export Γ
export interpolate
export complex2angleString
export complex2angle
export equationToDataNetwork
export readHFSSPattern
export RadiationPattern
export ArrayFactor
export generateRectangularAF

include("Constants.jl")

abstract type AbstractNetwork end
abstract type AbstractRadiatonPattern end

"""
The base Network type for representing n-port linear networks with characteristic impedance Z0.
  By default, the network is stored as S-Parameters with the corresponding frequency list.
"""
mutable struct DataNetwork <: AbstractNetwork
  ports::Int
  Z0::Union{Real,Complex}
  frequency::Array{Real,1}
  s_params::Array{Array{Union{Real,Complex},2},1}
end

function DataNetwork(ports::Int,Z0::Number,frequency::Array{A,1},s_params::Array{B,1}) where {A <: Number, B <: Number}
  # Hacky fix as 1x1 array still needs to be Array{T,2}
  s_params = [hcat(param) for param in s_params]
  DataNetwork(ports,Z0,frequency,s_params)
end

function ==(a::DataNetwork,b::DataNetwork)
  a.ports == b.ports &&
  a.Z0 == b.Z0 &&
  a.frequency == b.frequency &&
  a.s_params == b.s_params
end

"""
The base Network type for representing n-port linear networks with characteristic impedance Z0.
  The S-Parameters for an EquationNetwork are defined by a function that returns a `ports`-square matrix
  and accepts kwargs `Z0` and `freq`. Please provide default arguments for any input parameters.
"""
mutable struct EquationNetwork <: AbstractNetwork
  ports::Int
  Z0::Union{Real,Complex}
  eq::Function
  function EquationNetwork(ports,Z0,eq)
    # Test that the equation is valid by checking size and args
    result = eq(freq = 1,Z0 = Z0)
    if ports == 1
      @assert size(result) == () "1-Port network must be built with a function that returns a single number."
    else
      @assert size(result) == (ports,ports) "n-Port network must be built with a function that returns an n-square matrix."
    end
    new(ports,Z0,eq)
  end
end

"""
    equationToDataNetwork(equationNet,args=(arg1,arg2),freqs=[1,2,3])
Utility function to convert an equation network to a data network by evaluating it at every frequency in the list
or range `freqs`.
"""
function equationToDataNetwork(network::EquationNetwork;args::Tuple=(),freqs::Union{StepRangeLen,Array})
  DataNetwork(network.ports,network.Z0,Array(freqs),[network.eq(args...,Z0=network.Z0,freq = f) for f in freqs])
end

"""
    RadiationPattern
Stores a 3D antenna radiation pattern in spherical coordinates.
Φ and Θ are in degrees, pattern is in dBi
"""
mutable struct RadiationPattern <: AbstractRadiatonPattern
    ϕ::Union{AbstractRange,Array}
    θ::Union{AbstractRange,Array}
    pattern::Array{Real,2}
end

"""
    ArrayFactor
Stores the array factor due to N isotropic radiators located at `locations` with
phasor excitations `excitations`. Calling an `ArrayFactor` object with the arguments
ϕ,θ,and frequency will return in dB the value of the AF at that location in spherical
coordinates.
"""
mutable struct ArrayFactor <: AbstractRadiatonPattern
  locations::Array{Tuple{Real,Real,Real}}
  excitations::Array{Complex}
end

function (af::ArrayFactor)(ϕ,θ,freq)
    # Construct wave vector
    λ = c₀/freq
    k = (2*π)/(λ) .* [sind(θ)*cosd(ϕ),sind(θ)*sind(ϕ),cosd(θ)]
    # Constuct steering vector
    v = [exp(-1im*k⋅r) for r in af.locations]
    # Create array factor
    return 10*log10(abs(transpose(af.excitations)*v))
end

"""
        generateRectangularAF(Nx,Ny,Spacingx,Spacingy,ϕ,θ,freq)
Creates an `ArrayFactor` object from arectangular array that is `Nx` X `Ny`
big with spacing `Spacingx` and `Spacingy`. The excitations are phased such that
the main beam is in the `ϕ`, `θ`, direction at frequency `freq`.
"""
function generateRectangularAF(Nx,Ny,Spacingx,Spacingy,ϕ,θ,freq)
    # Create Locations
    Locations = []
    # 1D
    if Nx == 0
        error("Needs at least one component in x")
    elseif Ny == 0
        error("Needs at least one component in y")
    else
        # 2D
        for i in 1:Nx, j in 1:Ny
            push!(Locations,((i-1)*Spacingx,(j-1)*Spacingy,0))
        end
    end
    R_Hat = [sind(θ)*cosd(ϕ),sind(θ)*sind(ϕ),cosd(θ)]
    # Calculate phases
    ω = 2*π*freq
    k = ω/c₀
    Phases = zeros(length(Locations))
    for (i,position) in enumerate(Locations)
        Phases[i] = -k*R_Hat'*[position...]*(180/π) % 360
        # Fix weird phases
        if Phases[i] < 0
            Phases[i] += 360 # Fix negative angles
        end
        if Phases[i] / 360 > 0.99999
            Phases[i] = 0 # Fix numbers close to 360
        end
        if Phases[i] < 1e-10
            Phases[i] = 0 # Fix some precision errors
        end
    end
    ArrayFactor(Locations,[∠(1,angle) for angle in Phases])
end

"""
        readHFSSPattern("myAntenna.csv")
Reads the exported fields from HFSS into a Marconi `RadiationPattern` object.
"""
function readHFSSPattern(filename::String)
    # Read Pattern
    patternData = CSV.read(filename) |> Matrix

    # Determine sampled space
    ϕ_min = Inf
    ϕ_max = -Inf
    θ_min = Inf
    θ_max = -Inf

    for i in 1:size(patternData)[1], j in 1:size(patternData)[2]-1
        # Check column 1 for phi, 2 for theta
        if j == 1
            if patternData[i,j] > ϕ_max
                ϕ_max = patternData[i,j]
            elseif patternData[i,j] < ϕ_min
                ϕ_min = patternData[i,j]
            end
        elseif j == 2
            if patternData[i,j] > θ_max
                θ_max = patternData[i,j]
            elseif patternData[i,j] < θ_min
                θ_min = patternData[i,j]
            end
        end
    end

    # Determine step size
    ϕ_step = patternData[2,1] - patternData[1,1]
    ϕ = ϕ_min:ϕ_step:ϕ_max
    θ_step = patternData[length(ϕ)+1,2] - patternData[1,2]
    θ = θ_min:θ_step:θ_max

    # Create pattern
    RadiationPattern(ϕ,θ,reshape(patternData[:,3],(length(ϕ),length(θ))))
end

function findmax(pattern::RadiationPattern)
    val,location = findmax(pattern.pattern)
    i = location[1]; j = location[2]
    return val,Array(pattern.ϕ)[i],Array(pattern.ϕ)[j]
end

function Base.show(io::IO,network::T) where {T <: AbstractNetwork}
  if T == DataNetwork
    println(io,"$(network.ports)-Port Network")
    println(io," Z0 = $(network.Z0)")
    println(io," Frequency = $(prettyPrintFrequency(network.frequency[1])) to $(prettyPrintFrequency(network.frequency[end]))")
    println(io," Points = $(length(network.frequency))")
  elseif T == EquationNetwork
    println(io,"$(network.ports)-Port Network")
    println(io," Z0 = $(network.Z0)")
    println(io," Equation-driven Network")
  end
end

function Base.show(io::IO,pattern::RadiationPattern)
  ϕ = Array(pattern.ϕ); θ = Array(pattern.θ)
  println(io,"$(length(pattern.pattern))-Element Radiation Pattern")
  println(io," Φ: $(ϕ[1]) - $(ϕ[end]) deg in $(ϕ[2]-ϕ[1]) deg steps")
  println(io," θ: $(θ[1]) - $(θ[end]) deg in $(θ[2]-θ[1]) deg steps")
end

function prettyPrintFrequency(freq::T) where {T <: Real}
  multiplierString = ""
  multiplier = 1
  if freq < 1e3
    multiplierString = ""
    multiplier = 1
  elseif 1e3 <= freq < 1e6
    multiplierString = "K"
    multiplier = 1e3
  elseif 1e6 <= freq < 1e9
    multiplierString = "M"
    multiplier = 1e6
  elseif 1e9 <= freq < 1e12
    multiplierString = "G"
    multiplier = 1e9
  elseif 1e12 <= freq < 1e15
    multiplierString = "T"
    multiplier = 1e12
  end
  return "$(freq/multiplier) $(multiplierString)Hz"
end

# File option enums
@enum paramType S Y Z G H
@enum paramFormat MA DB RI

"""
    readTouchstone("myFile.sNp")

Reads the contents of `myFile.sNp` into a Network object.
This will convert all file types to S-Parameters, Real/Imaginary

Currently does not support reference lines (Different port impedances) or noise parameters
"""
function readTouchstone(filename::String)
  # File option settings - defaults
  thisfreqExponent = 1e9
  thisParamType = S
  thisParamFormat = MA
  thisZ0 = 50.

  # Setup blank network object to build from
  thisNetwork = DataNetwork(0,0,[],[])

  # Open the file
  open(filename) do f
    while !eof(f)
      line = readline(f)
      if line == "" || line[1] == '!' # Ignore comment lines and empty lines
        continue
      elseif line[1] == '#' # Parse option line
        # Option line contains [HZ/KHZ/MHZ/GHZ] [S/Y/Z/G/H] [MA/DB/RI] [R n]
        # Or contains nothing implying GHZ S MA R 50
        options = line[2:end]
        if length(options) == 0
          continue # Use defaults
        else
          options = split(strip(options))
          # Some VNAs put random amounts of spaces between the options,
          # so we have to remove all the empty entries
          options = [option for option in options if option != ""]

          # Process frequency exponent
          if lowercase(options[1]) == "hz"
            thisfreqExponent = 1.
          elseif lowercase(options[1]) == "khz"
            thisfreqExponent = 1e3
          elseif lowercase(options[1]) == "mhz"
            thisfreqExponent = 1e6
          elseif lowercase(options[1]) == "ghz"
            thisfreqExponent = 1e9
          end

          # Process Parameter Type
          if lowercase(options[2]) == "s"
            thisParamType = S
          elseif lowercase(options[2]) == "y"
            thisParamType = Y
          elseif lowercase(options[2]) == "z"
            thisParamType = Z
          elseif lowercase(options[2]) == "g"
            thisParamType = G
          elseif lowercase(options[2]) == "h"
            thisParamType = H
          end

          # Process Parameter Format
          if lowercase(options[3]) == "ma"
            thisParamFormat = MA
          elseif lowercase(options[3]) == "db"
            thisParamFormat = DB
          elseif lowercase(options[3]) == "ri"
            thisParamFormat = RI
          end

          # Process Z0
          thisZ0 = parse(Float64,options[5])
        end
      else # Process everything else
        freq, ports, params = processTouchstoneLine(line,thisfreqExponent,thisParamType,thisParamFormat,thisZ0)
        thisNetwork.ports = ports
        thisNetwork.Z0 = thisZ0
        push!(thisNetwork.frequency,freq)
        push!(thisNetwork.s_params,params)
      end
    end
  end

  # Return the constructed network
  return thisNetwork
end

"Internal function to process touchstone lines"
function processTouchstoneLine(line::String,freqExp::Real,paramT::paramType,paramF::paramFormat,Z0::T) where {T <: Number}
  lineParts = [data for data in split(line) if data != ""]
  frequency = parse(Float64,lineParts[1]) * freqExp
  ports = √((length(lineParts)-1)/2) # Parameters are in two parts for each port
  if mod(ports,1) != 0
    throw(DimensionMismatch("Parameters in file are not square, somethings up"))
  end
  ports = floor(Int,ports) # It needs to be an Int anyway

  # Step 1, get the parameters into RI format as that's what we will use
  params = zeros(Complex,ports,ports)
  for i = 2:2:(ports*ports*2) # Skip frequency
    # There will be ports*ports number of parameters
    paramIndex = floor(Int,i/2)
    if paramF == RI # Real Imaginary
      # Do nothing, already in the right type
      params[paramIndex] = parse(Float64,lineParts[i]) + 1.0im * parse(Float64,lineParts[i+1])
    elseif paramF == MA # Magnitude Angle(Degrees)
      mag = parse(Float64,lineParts[i])
      angle = parse(Float64,lineParts[i+1])
      params[paramIndex] = mag  * cosd(angle) +
                           1.0im * mag  * sind(angle)
    elseif paramF == DB # dB Angle
      mag = 10^(parse(Float64,lineParts[i])/20)
      angle = parse(Float64,lineParts[i+1])
      params[paramIndex] = mag  * cosd(angle) +
                           1.0im * mag  * sind(angle)
    end
  end

  # Step 2, convert into S-Parameters
  if paramT == S
    # Do nothing, they are already S
  elseif paramT == Z
    params = z2s(params,Z0=Z0)
  elseif paramT == Y
    params = y2s(params,Z0=Z0)
  end # TODO H and G Parameters

  return frequency,ports,params
end

"""
    writeTouchstone(network,filename)

Writes a Touchstone file from a Marconi network.
"""
function writeTouchstone(network::AbstractNetwork,filename::String)
  body = "! Generated from Marconi.jl"
  body *= "\n# Hz S RI R 50\n"
  if network.ports == 1
    for i in 1:length(network.frequency)
      body *= "$(network.frequency[i])\t"
      body *= "$(real(network.s_params[i][1,1]))\t"
      body *= "$(imag(network.s_params[i][1,1]))\n"
    end
  elseif network.ports == 2
    for i in 1:length(network.frequency)
      # In the order S11, S21, S12, S22
      body *= "$(network.frequency[i])\t"
      body *= "$(real(network.s_params[i][1,1]))\t"
      body *= "$(imag(network.s_params[i][1,1]))\t"

      body *= "$(real(network.s_params[i][2,1]))\t"
      body *= "$(imag(network.s_params[i][2,1]))\t"

      body *= "$(real(network.s_params[i][1,2]))\t"
      body *= "$(imag(network.s_params[i][1,2]))\t"

      body *= "$(real(network.s_params[i][2,2]))\t"
      body *= "$(imag(network.s_params[i][2,2]))\n"
    end
  elseif network.ports >= 2

  end
  io = open(filename, "w")
  print(io, body)
  close(io)
end


function isPassive(network::T) where {T <: AbstractNetwork}
  for parameter in network.s_params
    for s in parameter
      if abs(s) > 1
        return false
      end
    end
  end
  # If we got through everything, then it's passive
  return true
end


function isReciprocal(network::T) where {T <: AbstractNetwork}
  # FIXME
  return true
end

function isLossless(network::T) where {T <: AbstractNetwork}
  # FIXME
  return true
end

"""
    testDelta(network)

Returns a vector of `Δ`, the determinant of the scattering matrix.
Optionally, returns `Δ` for S-Parameters at position `pos`.
"""
function testDelta(network::T;pos::Int = 0) where {T <: DataNetwork}
  @assert network.ports == 2 "Stability tests must be performed on two port networks"
  if pos == 0
    return [det(param) for param in network.s_params]
  else
    return det(network.s_params[pos])
  end
end

"""
    testMagDelta(network)

Returns a vector of `Δ`, the determinant of the scattering matrix.
Optionally, returns `|Δ|` for S-Parameters at position `pos`.
"""
function testMagDelta(network::T; pos::Int = 0) where {T <: DataNetwork}
  @assert network.ports == 2 "Stability tests must be performed on two port networks"
  if pos == 0
    return [abs(x) for x in testDelta(network)]
  else
    return abs(testDelta(network,pos=pos))
  end
end

"""
    testK(network)

Returns a vector of the magnitude of `K`, the Rollet stability factor.
"""
function testK(network::T;pos = 0) where {T <: DataNetwork}
  @assert network.ports == 2 "Stability tests must be performed on two port networks"
  if pos == 0
    magDelta = [abs(delta) for delta in testDelta(network)]
    return [(1 - abs(network.s_params[i][1,1])^2 - abs(network.s_params[i][2,2])^2 + magDelta[i]^2) /
            (2*abs(network.s_params[i][1,2])*abs(network.s_params[i][2,1])) for i = 1:length(network.frequency)]
  else
    return (1 - abs(network.s_params[pos][1,1])^2 - abs(network.s_params[pos][2,2])^2 + testMagDelta(network,pos=pos)^2) /
           (2*abs(network.s_params[pos][1,2])*abs(network.s_params[pos][2,1]))
  end
end

"""
    testMUG(network)

Returns a vector of the maximum unilateral gain of a network.
"""
function testMUG(network::DataNetwork)
  @assert network.ports == 2 "Gain calculations must be performed on two port networks"
  [abs(s[2,1])^2 / ( (1-abs(s[1,1])^2) * (1-abs(s[2,2])^2) ) for s in network.s_params]
end

"""
    testMSG(network)

Returns a vector of the maximum stable gain of a network.
"""
function testMSG(network::DataNetwork)
  @assert network.ports == 2 "Gain calculations must be performed on two port networks"
  [abs(s[2,1]) / abs(s[1,2]) for s in network.s_params]
end

"""
    testMAG(network)

Returns a vector of the maximum available gain of a network.
"""
function testMAG(network::DataNetwork)
  @assert network.ports == 2 "Gain calculations must be performed on two port networks"
  K = testK(network)
  [K[i] > 1 ? (1/(K[i]+sqrt(K[i]^2-1))) * (abs(network.s_params[i][2,1])/abs(network.s_params[i][1,2])) : NaN for i in 1:length(network.frequency)]
end

"""
    ∠(mag,angle)

A nice compact way of representing phasors. Angle is in degrees.
"""
function ∠(a,b)
  a*exp(im*deg2rad(b))
end

"""
    inputZ(Zr,Θ,Z0)

Calculates the input impedace of a lossless transmission line of length `θ` in degrees terminated with `Zr`.
Z0 is optional and defaults to 50.
"""
inputZ(Zr,θ;Z0=50.) = Z0*((Zr+Z0*im*tand(θ))/(Z0+Zr*im*tand(θ)))

"""
    inputZ(Γ,Z0)

Calculates the input impedace from complex reflection coefficient `Γ`.
Z0 is optional and defaults to 50.
"""
inputZ(Γ;Z0=50.) = Z0*(1+Γ)/(1-Γ)

"""
    Γ(Z,Z0)

Calculates the complex reflection coefficient `Γ` from impedance `Z`.
Z0 is optional and defaults to 50.
"""
Γ(Z;Z0=50.) = (Z-Z0)/(Z+Z0)

complex2angle(num::Complex) = (abs(num),atand(imag(num),real(num)))

function complex2angleString(num::Complex)
  vals = complex2angle(num)
  @sprintf "%.3f∠%.3f°" vals[1] vals[2]
end



# Sub files, these need to be at the end here such that the files have access
# to the types defined in this file
include("NetworkParameters.jl")
include("MarconiPlots.jl")
#include("Metamaterials.jl")
end # Module End

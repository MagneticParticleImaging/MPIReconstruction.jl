import Base.length, Base.size

export getSF, SVD, tikhonovLU, setlambda

function converttoreal{T}(S::AbstractArray{Complex{T}},f)
  N = prod(calibSize(f))
  M = div(length(S),N)
  S = reshape(S,N,M)
  S = reinterpret(T,S,(2*N,M))
  p = Progress(M, 1, "Converting system matrix to real...")
  for l=1:M
    tmp = S[:,l]
    S[1:N,l] = tmp[1:2:end]
    S[N+1:end,l] = tmp[2:2:end]
    next!(p)
  end
  return S
end

# Systemfunction types for better inversion algorithms
abstract type Systemfunction end

#type for singular value decomposition
@doc "This Type stores the singular value decomposition of a Matrix" ->
type SVD <: Systemfunction
  U::Matrix
  Σ::Vector
  V::Matrix
  D::Vector
end

SVD(U::Matrix,Σ::Vector,V::Matrix) = SVD(U,Σ,V,1./Σ)

size(A::SVD) = (size(A.U,1),size(A.V,1))
length(A::SVD) = prod(size(A))

@doc "This function can be used to calculate the singular values used for Tikhonov regularization." ->
function setlambda(A::SVD, λ::Real)
  for i=1:length(A.Σ)
    σi = A.Σ[i]
    A.D[i] = σi/(σi*σi+λ*λ)
  end
  return nothing
end

#type for Gauß elimination
type tikhonovLU <: Systemfunction
  S::Matrix
  LUfact
end

tikhonovLU(S::AbstractMatrix) = tikhonovLU(S, lufact(S'*S))

size(A::tikhonovLU) = size(A.S)
length(A::tikhonovLU) = length(A.S)

@doc "This function can be used to calculate the singular values used for Tikhonov regularization." ->
function setlambda(A::tikhonovLU, λ::Real)
  A.LUfact = lufact(A.S'*A.S + λ*speye(size(A,2),size(A,2)))
  return nothing
end

setlambda(S::AbstractMatrix, λ::Real) = nothing

function getSF(bSF, frequencies, sparseTrafo, solver; kargs...)
  SF, grid = getSF(bSF, frequencies, sparseTrafo; kargs...)
  if solver == "kaczmarz"
    return transp(SF), grid
  elseif solver == "pseudoinverse"
    return SVD(svd(SF.')...), grid
  elseif solver == "cgnr" || solver == "lsqr" || solver == "fusedlasso"
    println("solver = $solver")
    return SF.', grid
  elseif solver == "direct"
    return tikhonovLU(SF.'), grid
  else
    return SF, grid
  end
end

getSF{T<:MPIFile}(bSF::Union{T,Vector{T}}, frequencies, sparseTrafo::Void; kargs...) = getSF(bSF, frequencies; kargs...)

# TK: The following is a hack since colored and sparse trafo are currently not supported
getSF{T<:MPIFile}(bSF::Vector{T}, frequencies, sparseTrafo::AbstractString; kargs...) = getSF(bSF[1],
   frequencies, sparseTrafo; kargs...)

function getSF{T<:MPIFile}(bSFs::Vector{T}, frequencies; kargs...)
  data = [getSF(bSF, frequencies; kargs...) for bSF in bSFs]
  return cat(1,[d[1] for d in data]...), data[1][2] # grid of the first SF
end

getSF(f::MPIFile; recChannels=1:numReceivers(f), kargs...) = getSF(f, filterFrequencies(f, recChannels=recChannels); kargs...)

function repairDeadPixels(S, shape, deadPixels)
  shapeT = tuple(shape...)
  #println(shapeT)
  for k=1:size(S,2)
    for dp in deadPixels
      ix,iy,iz = ind2sub(shapeT,dp)
      if 1<ix<shape[1] && 1<iy<shape[2] && 1<iz<shape[3]
         #println("$ix $iy $iz")
         lval = S[ sub2ind(shapeT,ix,iy+1,iz)  ,k]
         rval = S[ sub2ind(shapeT,ix,iy-1,iz)  ,k]
         S[dp,k] = 0.5*(lval+rval)
         fval = S[ sub2ind(shapeT,ix+1,iy,iz)  ,k]
         bval = S[ sub2ind(shapeT,ix-1,iy,iz)  ,k]
         S[dp,k] = 0.5*(fval+bval)
         uval = S[ sub2ind(shapeT,ix,iy,iz+1)  ,k]
         dval = S[ sub2ind(shapeT,ix,iy,iz-1)  ,k]
         S[dp,k] = 0.5*(uval+dval)
      end
    end
  end
end

function getSF(bSF::MPIFile, frequencies; returnasmatrix = true, procno::Integer=1,
               bgcorrection=false, loadasreal=false, loadas32bit=true,
               gridsize=collect(calibSize(bSF)), fov=calibFov(bSF), center=[0.0,0.0,0.0],
               deadPixels=Int[], kargs...)

  nFreq = rxNumFrequencies(bSF)

  S = getSystemMatrix(bSF, frequencies, loadas32bit=loadas32bit, bgCorrection=bgcorrection)

  if !isempty(deadPixels)
    repairDeadPixels(S,gridsize,deadPixels)
  end

  if collect(gridsize) != collect(calibSize(bSF)) ||
     center != [0.0,0.0,0.0] ||
     fov != calibFov(bSF)
    println("Do SF Interpolation...")
    #println(gridsize, fov, center, calibSize(bSF), calibFov(bSF))

    origin = RegularGridPositions(calibSize(bSF),calibFov(bSF),[0.0,0.0,0.0])
    target = RegularGridPositions(gridsize,fov,center)

    SInterp = zeros(eltype(S),prod(gridsize),length(frequencies))
    for k=1:length(frequencies)
      A = MPIFiles.interpolate(reshape(S[:,k],calibSize(bSF)...), origin, target)
      SInterp[:,k] = vec(A)
    end
    S = SInterp
    grid = target
  else
    grid = RegularGridPositions(calibSize(bSF),calibFov(bSF),[0.0,0.0,0.0])
  end

  if loadasreal
    S = converttoreal(S,bSF)
    resSize = [gridsize..., 2*length(frequencies)]
  else
    resSize = [gridsize..., length(frequencies)]
  end

  if returnasmatrix
    return reshape(S,prod(resSize[1:end-1]),resSize[end]), grid
  else
    return squeeze(reshape(S,resSize...)), grid
  end
end

"""
This function reads the component belonging to the given mixing-factors und chanal from the given MPIfile.\n
In the case of a 2D systemfunction, the third dimension is added.
"""
function getSF(bSF::MPIFile, mx::Int, my::Int, mz::Int, recChan::Int)
  maxFreq  = rxNumFrequencies(bSF)
	freq = mixFactorToFreq(bSF, mx, my, mz)
	freq = clamp(freq,0,maxFreq-1)
	k = freq + (recChan-1)*maxFreq
  println("k = $k")
	SF, grid = getSF(bSF,[k+1],returnasmatrix = true, bgcorrection=true)
  N = calibSize(bSF)
  SF = reshape(SF,N[1],N[2],N[3])

  return SF
end

include("Sparse.jl")

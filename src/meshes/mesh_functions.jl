import Base: eltype, length, indices, getindex, start, done, next, append!, push!,
              sort, getindex, setindex!, size, map, zip, eltype, iteratorsize,
              iteratoreltype, empty!

export domain, image, graph, idxtype, cell_type, reserve

using StaticArrays
using Base.OneTo
import TipiFEM.Utils: compose, decompose, flatten
# note if the mesh function needs to communicate with the mesh we should
#  do this by means of events
# todo: ensure that the indices are sorted

"""
Discrete function that takes an index of cells with fixed dimension mapping
it to an object of type `eltype(VI)`.
"""
abstract type MeshFunction{K, V} end

"""
Construct an empty mesh function mapping cells of type K to values of type V

```
MeshFunction(Polytope"3-node triangle", Int64)
```
"""
function MeshFunction(::Type{K}, ::Type{V}, ::Val{simple}) where {K <: Cell, V, simple}
  # call type trait to see which concrete type we need
  find_appropriate_mesh_function(K, V)(K, V, Val{simple}())
end

MeshFunction(::Type{K}, ::Type{V}) where {K <: Cell, V} = MeshFunction(K, V, Val{true}())

find_appropriate_mesh_function(::DataType, ::Type) = HomogenousMeshFunction
find_appropriate_mesh_function(::Union, ::Type) = HeterogenousMeshFunction
find_appropriate_mesh_function(::UnionAll, ::Type) = GenericMeshFunction

"""
Construct a mesh function with domain `indices` and image `values`
"""
function MeshFunction(indices::II, values::VI) where {II <: Union{AbstractArray, Range}, VI}
  length(size(values)) == 1 || error("MeshFunctions may only be initialized from 1-dimensional arrays")
  let K = cell_type(eltype(indices)), V = fulltype(eltype(values))
    find_appropriate_mesh_function(K, V){K, V}(indices, values)
  end
end

function MeshFunction{II, VI}(::Type{II}, ::Type{VI})
  let K = cell_type(eltype(II)), V = fulltype(eltype(VI))
    find_appropriate_mesh_function(K, V){K, V, II, VI}()
  end
end

# todo: implement ∪

#todo: rename into compose
compose(mfs::MeshFunction...) = HeterogenousMeshFunction(mfs)

import Base: length, size, indices, eltype, start, next, done, map, foreach, iteratorsize, iteratoreltype, eltype

struct GraphIterator{II, VI}
  indices::II
  values::VI
end

length(z::GraphIterator) = Base.Iterators._min_length(z.indices, z.values, iteratorsize(z.indices), iteratorsize(z.values))
size(z::GraphIterator) = promote_shape(size(z.indices), size(z.values))
indices(z::GraphIterator) = promote_shape(indices(z.indices), indices(z.values))
eltype{I1,I2}(::Type{GraphIterator{I1,I2}}) = Tuple{eltype(I1), eltype(I2)}
@inline start(z::GraphIterator) = (start(z.indices), start(z.values))
@inline function next(z::GraphIterator, st)
    n1 = next(z.indices,st[1])
    n2 = next(z.values,st[2])
    return ((n1[1], n2[1]), (n1[2], n2[2]))
end
@inline done(z::GraphIterator, st) = done(z.indices,st[1]) | done(z.values,st[2])
map(f::Function, z::GraphIterator) = MeshFunction(z.indices, map(f, z.indices, z.values))
foreach(f::Function, z::GraphIterator) = foreach(f, z.indices, z.values)

iteratorsize{I1,I2}(::Type{GraphIterator{I1,I2}}) = Base.Iterators.zip_iteratorsize(iteratorsize(I1),iteratorsize(I2))
iteratoreltype{I1,I2}(::Type{GraphIterator{I1,I2}}) = Base.Iterators.and_iteratoreltype(iteratoreltype(I1),iteratoreltype(I2))

graph(mf::MeshFunction) = GraphIterator(domain(mf), image(mf))
@typeinfo idxtype{K, V}(::Type{MeshFunction{K, V}}) = Union{map(K -> Id{K}, uniontypes(K))...}
@typeinfo cell_type{K, V}(::Type{MeshFunction{K, V}}) = K
@typeinfo cell_types{K, V}(::Type{MeshFunction{K, V}}) = uniontypes(K)
@typeinfo idxtype{MF <: MeshFunction}(::Type{MF}) = idxtype(supertype(MF))
@typeinfo cell_type{MF <: MeshFunction}(::Type{MF}) = cell_type(supertype(MF))
@typeinfo cell_types{MF <: MeshFunction}(::Type{MF}) = cell_types(supertype(MF))

eltype(mf::MeshFunction) = eltype(image(mf))
length(mf::MeshFunction) = length(image(mf))
start(mf::MeshFunction) = start(image(mf))
done(mf::MeshFunction, state) = done(image(mf), state)
next(mf::MeshFunction, state) = next(image(mf), state)

getindex(mf::MeshFunction, i::Id) = throw(MethodNotImplemented())
getindex(mf::MeshFunction, i::Id, j::Int) = mf[i][j]
setindex!(mf::MeshFunction, v, i::Id) = throw(MethodNotImplemented())
setindex!(mf::MeshFunction, v, i::Id, j::Int) = throw(MethodNotImplemented())

function size(mf::MeshFunction)
  @assert size(domain(mf)) == size(image(mf))
  size(domain(mf))
end

"Transform the image of the mesh function `mf` by applying `f` to each element"
map(f::Function, mf::MeshFunction) = MeshFunction(domain(mf), map(f, image(mf)))

"""
For a set of mesh functions return a mesh function of tuples, where the
`i`th tuple contains in the `j`th component the value of the `j`th mesh
function at `i`

```@repl
mf1 = MeshFunction(Polytope"1-node point", Int)
mf2 = MeshFunction(Polytope"1-node point", String)
push!(mf1, 1); push!(mf1, 2)
push!(mf2, "First"); push!(mf2, "Second")
mf = zip(mf1, mf2)
```
"""
function zip(mf::MeshFunction...)
  domain(mf1)==domain(mf2) || throw(ArgumentError("domain of each mesh function must match"))
  MeshFunction(domain(mf1), zip(image(mf1), image(mf2)))
end

function zip(mf1::MeshFunction, mf2::MeshFunction)
  domain(mf1)==domain(mf2) || throw(ArgumentError("domain of each mesh function must match"))
  MeshFunction(domain(mf1), zip(image(mf1), image(mf2)))
end

"""
construct a new mesh function with only the values in the i-th row
of each element in mf
"""
function getindex(mf::MeshFunction, i::Int, j::Colon)
  assert(eltype(mf) <: StaticVector)
  MeshFunction(domain(mf), reinterpret(eltype(eltype(mf)), image(mf), (size(eltype(mf), 1), length(mf)))[i, j])
end

import Base: summary

summary(mf::MeshFunction) = "$(length(mf)) element $(typeof(mf).name.name) $(cell_type(mf)) → $(eltype(mf))"

function show(io::IO, ::MIME"text/plain", mf::MeshFunction; tree=false)
  #bold = "\x1b[1m"; default = "\x1b[0m";
  tree && write(io, "├─ ")
  write(io, "$(summary(mf))\n")
  # print a maximum of 10 values
  if length(mf)<10
    for (idx, val) in graph(mf)
      tree && write(io, "|  ")
      write(io, " ")
      if typeof(idxtype(mf)) == DataType
        show(io, (convert(Int, idx), val))
      else
        show(io, (idx, val))
      end
      write(io, "\n")
    end
  elseif length(mf)>=10
    c=0
    for (idx, val) in graph(mf)
      tree && write(io, "|  ")
      if typeof(idxtype(mf)) == DataType
        show(io, (convert(Int, idx), val))
      else
        show(io, (idx, val))
      end
      write(io, "\n")
      if ((c+=1)==10)
        break;
      end
    end
    write(io, "...\n")
  end
end

#
# HomogenousMeshFunction
#
"""
Resolves indices associated with a single cell type to their mapped values.
"""
type HomogenousMeshFunction{K, V, II, VI} <: MeshFunction{K, V}
  indices::II
  values::VI

  function (::Type{HomogenousMeshFunction{K, V}})(indices::II, values::VI) where {K <: Cell, V, II, VI}
    @assert eltype(indices) <: Id "eltype(indices) = $(eltype(indices)) must be a subtype of $(Id)"
    @assert eltype(indices) == Id{K} "Type parameter K = $(K) does not match " *
                                        "cell_type(eltype(indices)) = $(cell_type(eltype(indices)))"
    @assert eltype(values) <: V "eltype(values) = $(eltype(values)) must be a subtype of the type parameter V"
    new{K, fulltype(V), II, VI}(indices, values)
  end

  function (::Type{HomogenousMeshFunction{K, V, II, VI}}){K <: Cell, V, II, VI}()
    # todo: check compatibility of K, V, II, VI
    new{K, fulltype(V), II, VI}(II(), VI())
  end
end

@generated HomogenousMeshFunction{K, V, simple}(::Type{K}, ::Type{V}, ::Val{simple}) = quote
  assert(isa(simple, Bool))
  indices = $(simple==true ? :(OneTo{Id{K}}(0)) : :(Vector{Id{K}}()))
  values = Array{fulltype(V), 1}()
  HomogenousMeshFunction{K, V}(indices, values)
end

HomogenousMeshFunction{K, V}(::Type{K}, ::Type{V}) = HomogenousMeshFunction(K, V, Val{true}())

function HomogenousMeshFunction{II, VI}(indices::II, values::VI)
  @assert eltype(indices) <: Id "eltype(indices) = $(eltype(indices)) must be a subtype of $(Id)"
  HomogenousMeshFunction{cell_type(eltype(indices)), eltype(values)}(indices, values)
end

domain(mf::HomogenousMeshFunction) = mf.indices
image(mf::HomogenousMeshFunction) = mf.values
idxtype{HMF <: HomogenousMeshFunction}(mf::Type{HMF}) = eltype(fieldtype(HMF, :indices))
eltype{HMF <: HomogenousMeshFunction}(mf::Type{HMF}) = eltype(fieldtype(HMF, :values))
domain_type{HMF <: HomogenousMeshFunction}(::Type{HMF}) = fieldtype(HMF, :indices)
image_type{HMF <: HomogenousMeshFunction}(::Type{HMF}) = fieldtype(HMF, :values)
"""
Return integer index from cell index
- If the domain is a range starting from 1 with step size 1 the cell index is
  and integer index are equal
- If the domain is a range with step size 1 the cell index and integer index
  are equal up to a constant
- If the domain is a generic array we search the complete domain until we find
  the integer index for the given cell index
"""
_get_idx(mf::HomogenousMeshFunction{<:Cell,<:Any,<:OneTo}, i::Id) = convert(Int, i)
_get_idx(mf::HomogenousMeshFunction{<:Cell,<:Any,<:UnitRange}, i::Id) = convert(Int, i)-first(domain(mf))+1
_get_idx(mf::HomogenousMeshFunction, i::Id) = findfirst(domain(mf), i)

getindex(mf::HomogenousMeshFunction, i::Int) = image(mf)[i]
getindex(mf::HomogenousMeshFunction, i::Id) = mf[_get_idx(mf, i)]
setindex!(mf::HomogenousMeshFunction, v, i::Int) = image(mf)[i] = v
setindex!(mf::HomogenousMeshFunction, v, i::Id) = mf[_get_idx(mf, i)] = v
setindex!(mf::HomogenousMeshFunction, v, i::Id, j::Int) = mf[_get_idx(mf, i), j] = v

#function &(mf1::HomogenousMeshFunction, mf2::HomogenousMeshFunction)
#  assert(domain(mf1) == domain(m2))
#  HomogenousMeshFunction(domain(mf1), image(mf1) & image(mf2))
#end

"Set the `j`-th element of `mf[i]` to to `v`"
function setindex!(mf::HomogenousMeshFunction{K, V}, v, i::Int, j::Int) where {K<:Cell, V<:AbstractArray}
  @boundscheck begin
    i <= length(mf) || throw(BoundsError(mf, i))
    j <= length(eltype(mf)) || throw(BoundsError(mf[i], j))
    @assert isbits(eltype(mf)) "eltype(mf) = $(eltype(mf)) is not a bits type"
  end
  unsafe_store!(convert(Ptr{eltype(eltype(mf))}, pointer(image(mf), i)), v, j)
  v
end

using SimpleRepeatIterator

function set_domain!(mf::HomogenousMeshFunction, domain)
  mf.indices = domain
end

function set_image!(mf::HomogenousMeshFunction, image)
  mf.values = image
end

function flatten(mf::HomogenousMeshFunction)
  # todo: better error handling
  _flatten(eltype(mf), mf)
end

function _flatten(::Type{T}, mf::HomogenousMeshFunction) where T <: Union{Tuple, StaticVector}
  MeshFunction(repeat(domain(mf), inner=length(eltype(mf).parameters)),
               reinterpret(eltype(eltype(mf)), image(mf),
                    (length(mf)*length(eltype(mf).parameters),)))
end

_flatten(eltype, mf::HomogenousMeshFunction) = error("Not implemented")

# todo: we also want sort!, but this only works if domain(mf) is already
#  an array
import Base.sort
function sort(mf::HomogenousMeshFunction; kwargs...)
  if !applicable(sortperm, image(mf))
    mf = MeshFunction(domain(mf), collect(image(mf)))
  end
  # get indices of the sorted sequence
  perm = sortperm(image(mf); kwargs...)
  # alocate new arrays for the indices and values
  indices = Array{idxtype(mf), 1}(length(mf))
  values = Array{eltype(mf), 1}(length(mf))
  for (ridx, perm_idx) in zip(1:length(mf), perm)
    indices[ridx] = domain(mf)[perm_idx]
    values[ridx] = image(mf)[perm_idx]
  end
  HomogenousMeshFunction(indices, values)
end

function getindex{T <: Cell}(mf::HomogenousMeshFunction, ::Type{T})
  @assert cell_type(mf) == T "Can not constrain homogenous mesh function to type $(T)"
  mf
end

#"""
#Cell types of the indices
#
#```@repl
#cell_types(MeshFunction(Polytope"3-node triangle", Int64))
#```
#"""
#@Base.pure cell_types(mf::MeshFunction) = cell_type(mf) (cell_type(eltype(mf.indices)),)
# todo: pull request homogenous constructor for OneTo, UnitRange, StepRange
for (indices_t, expr) in [
      OneTo => :(OneTo(stop)),
      UnitRange => :(UnitRange(first(mf.indices), stop)),
      StepRange => :(StepRange(first(mf.indices), step(mf.indices), stop))
    ]
  @eval function push!(mf::HomogenousMeshFunction{K, V, II}, v::T) where {K, V, II <: $(indices_t), T}
    stop = last(mf.indices)+step(mf.indices)
    mf.indices = $(expr) # allocate a new index
    push!(mf.values, v)
    mf
  end
end

function push!(mf::HomogenousMeshFunction, ::Type{K}, v::T) where {K <: Cell, T}
  @assert cell_type(mf) == K "Can not add a value belonging to a cell of type "*
                             "$(K) into a mesh function with cell type $(cell_type(mf))"
  push!(mf, v)
end

function push!(mf::HomogenousMeshFunction{K, V, II}, i::Id{K}, v::T) where {K <: Cell, V, II <: AbstractArray, T}
  push!(mf.indices, i)
  push!(mf.values, v)
  mf
end

"""
Decompose `HomogenousMeshFunction` into a set of `HomogenousMeshFunction`s

Note: This function is just defined for convenience, such that algorithms
can treat `Homogenous`- and `HeterogenousMeshFunction`s equally.
"""
function decompose(mf::HomogenousMeshFunction)
  (mf,)
end

"""
Copy indices and values of `mf2` to `mf1`

Note: This function is just defined for convenience, such that algorithms
can treat `Homogenous`- and `HeterogenousMeshFunction`s equally.
"""
function setindex!{MF <: HomogenousMeshFunction, T <: Cell}(mf1::MF, mf2::MF, ::Type{T})
  cell_type(mf1) == cell_type(mf2) == T || error("Invalid cell type")
  mf1.indices = mf2.indices
  mf1.values = mf2.values
end

import Base.resize!
function resize!(mf::HomogenousMeshFunction, n::Int, v=nothing)
  pn = length(mf)
  # resize indices array
  if typeof(domain(mf)) <: OneTo
    mf.indices = OneTo(idxtype(mf)(n))
  elseif typeof(domain(mf)) <: UnitRange
    mf.indices = idxtype(mf)(1):idxtype(mf)(n)
  elseif typeof(domain(mf)) <: StepRange
    mf.indices = idxtype(mf)(1):step(domain(mf)):idxtype(mf)(n)
  else
    resize!(domain(mf), n)
  end
  # resize values array
  resize!(image(mf), n)
  # intialize values array
  if v!=nothing
    for i in 1:n
      mf[i] = v
    end
  end
  mf
end

empty!(mf::HomogenousMeshFunction) = resize!(mf, 0)

# todo: write append

#
# GenericMeshFunction
#
#using DataStructures
#
#type IndexAllocatorPair
#  typ::DataType
#  idx::Int
#end

#"""
#Resolves indices associated with multiple not a priori known cell types to
#their mapped values.
#
#Note that neither domain nor image need to be sorted by their cell type. This
#however comes at a price of higher runtime. Therefore it is recommended to
#convert this function into a type stable HeterogenousMeshFunction after
#the generic features are not required anymore.
#"""
#type GenericMeshFunction{K<:Cell, V, II, VI} <: MeshFunction{K, V}
#  indices::II
#  values::VI
#  #length::Int
#
#  index_allocator::Array{IndexAllocatorPair, 1}
#  values_types::Dict{Type, Type}
#
#  GenericMeshFunction(indices, values) = new(indices, values, Array{IndexAllocatorPair, 1}(), Dict{Type, Type}())
#end
#
#function GenericMeshFunction{K <: Cell, V}(::Type{K}, ::Type{V})
#  indices = Array{Index, 1}()
#  values = Array{V, 1}()
#  GenericMeshFunction{typeof(indices), typeof(values)}(indices, values)
#end
#
#domain(mf::GenericMeshFunction) = mf.indices
#image(mf::GenericMeshFunction) = mf.values
#
#cell_type(mf::GenericMeshFunction) = Union{map(x->x.typ, mf.index_allocator)...}
#
#reserve(mf::GenericMeshFunction, n::Int) = resize!(mf)
#
#
#function allocate_index{K <: Cell}(mf::GenericMeshFunction, ::Type{K})
#  raw_idx=1
#  for x in mf.index_allocator
#    if x.typ==K
#      raw_idx=x.idx+=1
#      break;
#    end
#  end
#  if raw_idx==1
#    push!(mf.index_allocator, IndexAllocatorPair(K, 1))
#  end
#  Index{K}(raw_idx)
#end
#
##todo: section about pushmeta popmeta usage for resizing arrays
#function push!{MF <: GenericMeshFunction, K <: Cell, T}(mf::MF, ::Type{K}, v::T)
#  # note: this is not thread safe
#  idx=allocate_index(mf, K)
#  push!(domain(mf), idx)
#  push!(image(mf), v)
#  idx
#end

#@trait_def IsSortedByCellType{X}
#@trait_impl IsSortedByCellType{HomogenousMeshFunction}
#@trait_impl IsSortedByCellType{HeterogenousMeshFunction}

#
# HeterogenousMeshFunction
#
# todo: zip, hcat, ... on chains should return chains again with
#  the corresponding iterators inside the chain and not outside
# This would allow MeshFunction(domain(mf), zip(image(mf), map(somefun, image(mf))))

# todo: allow usage of a single array for heterogenous mesh functios
using Base.uniontypes

"""
Resolves indices whose associated cell type is of a fixed dimension to their
mapped values.
"""
type HeterogenousMeshFunction{Ks <: Cell, Vs, HMFs <: Tuple} <: MeshFunction{Ks, Vs}
  homogenous_mfs::HMFs

  function (::Type{HeterogenousMeshFunction{Ks, Vs}})(mfs::NTuple{N, HomogenousMeshFunction}) where {N, Ks <: Cell, Vs}
    length(mfs)!=0 || error("not allowed")
    new{Ks, Vs, typeof(mfs)}(mfs)
  end
end

@generated function HeterogenousMeshFunction(mfs::NTuple{N, MeshFunction}) where N
  Ks = :(Union{})
  Vs = :(Union{})
  mfs_expr = Expr(:tuple)
  for (i, mf) in enumerate(mfs.parameters)
    if mf <: HeterogenousMeshFunction
      for j in 1:length(fieldtype(mf, :homogenous_mfs).parameters)
        push!(mfs_expr.args, :(mfs[$(i)].homogenous_mfs[$(j)]))
        Ks = :(Union{$(Ks), cell_type($(last(mfs_expr.args)))})
        Vs = :(Union{$(Vs), eltype($(last(mfs_expr.args)))})
      end
    elseif mf <: HomogenousMeshFunction
      push!(mfs_expr.args, :(mfs[$(i)]))
      Ks = :(Union{$(Ks), cell_type($(last(mfs_expr.args)))})
      Vs = :(Union{$(Vs), eltype($(last(mfs_expr.args)))})
    else
      error("mf type $(mf) not supported")
    end
  end
  :(HeterogenousMeshFunction{$(Ks), $(Vs)}($(mfs_expr)))
end

#function &(mf1::HeterogenousMeshFunction, mf2::HeterogenousMeshFunction)
#  assert(domain(mf1) == domain(m2))
#  HeterogenousMeshFunction((hmf1 & hmf2 for (hmf1, hmf2) in zip(decompose(mf1), decompose(mf2)))...)
#end

#using Iterators.link_types
#
#@generated function _fieldtype_from_iterators(::Type{IIC}, values::Type{VIC}) where {IIC <: Chain, VIC <: Chain}
#  expr = Expr(:tuple)
#  for (II, VI) in zip(link_types(IIC), link_types(VIC))
#    push!(expr.args, HeterogenousMeshFunction{cell_type(eltype(II)), eltype(VI)})
#  end
#  expr
#end

using Base.@pure

@generated function HeterogenousMeshFunction(::Type{K}, ::Type{V}, ::Val{simple}) where {K <: Cell, V, simple}
  typeof(K) == Union || error("type $(K) is not Union type. Maybe you meant a HomogenousMeshFunction?")
  Ks = uniontypes(K)
  Vs = typeof(V) == Union ? uniontypes(V) : [V for i in 1:length(Ks)]
  MFs = map((K, V) -> :(HomogenousMeshFunction($(K), $(V), $(Val{simple}()))), Ks, Vs)
  :(HeterogenousMeshFunction(($(MFs...),)))
end

HeterogenousMeshFunction{Ks <: Cell, Vs}(::Type{Ks}, ::Type{Vs}) = HeterogenousMeshFunction(Ks, Vs, Val{true}())

#function IsSortedByCellType(mf::GenericMeshFunction)
#  mf = MeshFunction(cell_type(mf), eltype(mf))
#
#end

domain(mf::HeterogenousMeshFunction) = compose(map(hmf -> domain(hmf), decompose(mf)))
image(mf::HeterogenousMeshFunction) = compose(map(hmf -> image(hmf), decompose(mf)))
@pure idxtype{HMF <: HeterogenousMeshFunction}(::Type{HMF}) = Union{(Id{K} for K in uniontypes(tparam(HMF, 1)))...}
@pure eltype{HMF <: HeterogenousMeshFunction}(::Type{HMF}) = Union{uniontypes(tparam(HMF, 2))...}
#@pure domain_type{HMF <: HeterogenousMeshFunction}(::Type{HMF}) = fieldtype(HMF, :indices)
#@pure image_type{HMF <: HeterogenousMeshFunction}(::Type{HMF}) = fieldtype(HMF, :values)

getindex(mf::HeterogenousMeshFunction, i::Id{K}) where K <: Cell = mf[K][i]
getindex(mf::HeterogenousMeshFunction, i::Id{K}, j::Int) where K <: Cell = mf[K][i, j]
setindex!(mf::HeterogenousMeshFunction, v, i::Id{K}) where K <: Cell = setindex!(mf[K], v, i)
setindex!(mf::HeterogenousMeshFunction, v, i::Id{K}, j::Int) where K <: Cell = setindex!(mf[K], v, i, j)

"""
Decompose `HeterogenousMeshFunction` into a set of `HomogenousMeshFunction`s
"""
function decompose(mf::HeterogenousMeshFunction)
  mf.homogenous_mfs
end

function empty!(mf::HeterogenousMeshFunction)
  # todo: implement using map!
  map(decompose(mf)) do homomf
    empty!(homomf)
    mf[cell_type(homomf)] = homomf
  end
end

"""
Returns an mesh function containing only cells of type T

```
# construct two mesh function
mf1=TipiFEM.Meshes.MeshFunction(Polytope"3-node triangle", String)
mf2=TipiFEM.Meshes.MeshFunction(Polytope"4-node quadrangle", String)
# add some dummy values representing two triangles and one quadrangle
push!(mf1, "triangle \#1")
push!(mf1, "triangle \#2")
push!(mf2, "quadrangle \#1")
# chain the two mesh functions
mf=mf1 ∪ mf2
@assert length(mf) == 3
# here we constrain the mesh function
@assert mf[Polytope"3-node triangle"] == mf2
```
"""
@generated function getindex{T <: Cell}(mf::HeterogenousMeshFunction, ::Type{T})
  hmf_indices = []
  Ks = Union{} # todo: change to tuple
  Vs = Union{}
  for (i, HMF) in enumerate(tparam(mf, 3).parameters)
    if cell_type(HMF) == T
      push!(hmf_indices, i)
      Ks = Union{Ks, cell_type(HMF)}
      Vs = Union{Ks, eltype(HMF)}
    end
  end
  if length(hmf_indices) == 0
    error("Can not constrain HeterogenousMeshFunction to type $(T)")
  elseif length(hmf_indices) == 1
    :(mf.homogenous_mfs[$(first(hmf_indices))])
  else
    homogenous_mfs = map(i -> :(mf.homogenous_mfs[$(i)]), hmf_indices)
    :(HeterogenousMeshFunction{$(Ks), $(Vs)}($(homogenous_mfs...)))
  end
end

import Base.setindex!
@generated function setindex!(mf1::HeterogenousMeshFunction, mf2::MF, ::Type{T}) where {MF <: HomogenousMeshFunction, T <: Cell}
  hmf_index = let hmf_indices = []
    for (i, HMF) in enumerate(tparam(mf1, 3).parameters)
      if cell_type(HMF) == T
        push!(hmf_indices, i)
      end
    end
    length(hmf_indices)==1 || error("setindex not supported")
    first(hmf_indices)
  end
  expr = Expr(:tuple)
  for i in 1:length(tparam(mf1, 3).parameters)
    if i==hmf_index
      push!(expr.args, :(mf2))
    else
      push!(expr.args, :(mf1.homogenous_mfs[$(i)]))
    end
  end
  quote
    mf1.homogenous_mfs = $(expr)
    mf1
  end
end

getindex{T <: Cell}(mf::HeterogenousMeshFunction, idx::Id{T}) = mf[T][idx]

function push!(mf::HeterogenousMeshFunction, ::Union{Type{K}, K}, v::T) where {K <: Cell, T}
  push!(mf[K], v)
  mf
end

function push!(mf::HeterogenousMeshFunction, i::Id{K}, v::T) where {K <: Cell, T}
  push!(mf[K], i, v)
  mf
end

# todo: check type stability and performance
function graph(mf::HeterogenousMeshFunction)
  compose(map(hmf -> graph(hmf), decompose(mf)))
end

# todo: this is a general pattern so it might be useful to create a macro for this
flatten(mf::HeterogenousMeshFunction) = compose(map(mf -> flatten(mf), decompose(mf)))

function show(io::IO, M::MIME"text/plain", mf::HeterogenousMeshFunction)
  write(io, "$(summary(mf))\n")
  for hmf in decompose(mf)
    show(io, M, hmf, tree=true)
  end
end

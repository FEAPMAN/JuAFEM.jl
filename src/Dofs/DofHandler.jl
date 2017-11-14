"""
    DofHandler

A `DofHandler` takes care of the degrees of freedom in the system.

```jldoctest dh
julia> g = generate_grid(Tetrahedron, (2,2,2));

julia> dh = DofHandler(g)
```

We can now add fields of a certain name and dimension to the dofhandler:

```jldoctest dh
julia> push!(dh, :temperature, 1);

julia> push!(dh, :displacements, 3);
```

When we are done with adding the fields, we need to close it:

```jldoctest dh
julia> close!(dh)
DofHandler
  Fields:
    temperature dim: 1
    displacements dim: 3
  Total dofs: 108
  Dofs per cell: 16
```

Can now do queries:

```jldoctest dh
julia> ndofs(dh)
108

julia> ndofs_per_cell(dh)
16

julia> global_dofs = zeros(Int, ndofs_per_cell(dh))

julia> dofs_cell!(global_dofs, dh, 3);

julia> global_dofs
16-element Array{Int64,1}:
 13
 37
 53
  6
  7
  8
 14
 15
 16
 38
 39
 40
 54
 55
 56
```

Can use it to export

```jldoctest dh
julia> a = rand(ndofs(dh))

julia> vtkfile = vtk_grid(grid)

julia> vtk_point_data(vtkfile)
```

"""
struct DofHandler{dim, N, T, M}
    # dofs_nodes::Matrix{Int}
    dofs_nodes::Vector{Int}
    dofs_nodes_offsets::Vector{Int}
    # dofs_cells::Matrix{Int} # TODO <- Is this needed or just extract from dofs_nodes?
    dofs_cells::Vector{Int}
    dofs_cells_offsets::Vector{Int}
    field_names::Vector{Symbol}
    dof_dims::Vector{Int}
    closed::ScalarWrapper{Bool}
    dofs_vec::Vector{Int}
    grid::Grid{dim, N, T, M} # TODO: Needed?
end

function DofHandler(m::Grid)
    # DofHandler(Matrix{Int}(0, 0), Matrix{Int}(0, 0), Symbol[], Int[], ScalarWrapper(false), Int[], m)
    DofHandler(Int[], fill(0, getnnodes(m)+1), Int[], Int[], Symbol[], Int[], ScalarWrapper(false), Int[], m)
end

function Base.show(io::IO, dh::DofHandler)
    println(io, "DofHandler")
    println(io, "  Fields:")
    for i in 1:length(dh.field_names)
        println(io, "    ", dh.field_names[i], " dim: ", dh.dof_dims[i])
    end
    if !isclosed(dh)
        println(io, "  Not closed!")
    else
        println(io, "  Total dofs: ", ndofs(dh))
        print(io, "  Dofs per cell: ", ndofs_per_cell(dh))
    end
end

ndofs(dh::DofHandler) = length(dh.dofs_nodes)
# TODO: This still assumes same in all cells
ndofs_per_cell(dh::DofHandler) = dh.dofs_cells_offsets[2] - dh.dofs_cells_offsets[1]
isclosed(dh::DofHandler) = dh.closed[]
function dofs_node(dh::DofHandler, i::Int)
    dh.dofs_nodes[dh.dofs_nodes_offsets[i]:(dh.dofs_nodes_offsets[i+1]-1)] # TODO: Probably wrong
end

# Stores the dofs for the cell with number `i` into the vector `global_dofs`
function celldofs!(global_dofs::Vector{Int}, dh::DofHandler, i::Int)
    @assert isclosed(dh)
    @assert length(global_dofs) == ndofs_per_cell(dh)
    # @inbounds for j in 1:ndofs_per_cell(dh)
    #     global_dofs[j] = dh.dofs_cells[j, i]
    # end
    @inbounds for j in 1:ndofs_per_cell(dh)
        global_dofs[j] = dh.dofs_cells[dh.dofs_cells_offsets[i]+j]
    end
    return global_dofs
end

# Add a field to the dofhandler ex `push!(dh, :u, 3)`
function Base.push!(dh::DofHandler, name::Symbol, dim::Int)
    @assert !isclosed(dh)
    if name in dh.field_names
        throw(ArgumentError("duplicate field name $(name)"))
    end
    push!(dh.field_names, name)
    push!(dh.dof_dims, dim)
    append!(dh.dofs_vec, length(dh.dofs_vec)+1:length(dh.dofs_vec) + dim * getnnodes(dh.grid))
    # for i in 1:getnnodes(dh.grid)+1
    #     dh.dofs_nodes_offsets[i] += dim*(i-1)
    # end
    return dh
end

# Computes the number of dofs from which the field starts data
# For example [ux, uy, uz, T] --> dof_offset(dh, :temperature) = 4
function dof_offset(dh::DofHandler, field_name::Symbol)
    @assert field_name ∈ dh.field_names
    offset = 0
    i = 0
    for name in dh.field_names
        if name == field_name
            return offset
        else
            i += 1
            offset += dh.dof_dims[i]
        end
    end
end

function ndim(dh::DofHandler, field_name::Symbol)
    @assert field_name ∈ dh.field_names
    i = 0
    for name in dh.field_names
        i += 1
        if name == field_name
            return dh.dof_dims[i]
        end
    end
end

function close!(dh::DofHandler)
    @assert !isclosed(dh)
    # dh.dofs_nodes = reshape(dh.dofs_vec, (length(dh.dofs_vec) ÷ getnnodes(dh.grid), getnnodes(dh.grid)))
    # dh.dofs_nodes = dh.dofs_vec
    # count = 0
    s = sum(dh.dof_dims)
    for i in 1:getnnodes(dh.grid)+1
        # count += s
        dh.dofs_nodes_offsets[i] = (i-1)*s + 1
    end

    copy!(resize!(dh.dofs_nodes, length(dh.dofs_vec)), dh.dofs_vec)
    add_element_dofs!(dh)
    dh.closed[] = true
    return dh
end

getnvertices(::Type{JuAFEM.Cell{dim, N, M}}) where {dim, N, M} = N

# Computes the "edof"-matrix
function add_element_dofs!(dh::DofHandler)
    n_elements = getncells(dh.grid)
    # n_vertices = getnvertices(getcelltype(dh.grid))
    element_dofs = Int[]
    ndofs = size(dh.dofs_nodes, 1)
    push!(dh.dofs_cells_offsets, 1)
    for element in 1:n_elements
        offset = 0
        for dim_doftype in dh.dof_dims
            for node in getcells(dh.grid, element).nodes
                for j in 1:dim_doftype
                    # push!(element_dofs, dh.dofs_nodes[offset + j, node])
                    o = dh.dofs_nodes_offsets[node]
                    push!(element_dofs, dh.dofs_nodes[dh.dofs_nodes_offsets[node] - 1 + offset + j])
                    # push!(dh.dofs_nodes_offsets, length(dh.dofs_nodes_offsets))
                end
            end
            offset += dim_doftype
        end
        push!(dh.dofs_cells_offsets, length(element_dofs)+1)
    end
    # dh.dofs_cells = reshape(element_dofs, (ndofs * n_vertices, n_elements))
    copy!(resize!(dh.dofs_cells, length(element_dofs)), element_dofs)
end

# Creates a sparsity pattern from the dofs in a dofhandler.
# Returns a sparse matrix with the correct pattern.
@inline create_sparsity_pattern(dh::DofHandler) = _create_sparsity_pattern(dh, false)
@inline create_symmetric_sparsity_pattern(dh::DofHandler) = Symmetric(_create_sparsity_pattern(dh, true), :U)

function _create_sparsity_pattern(dh::DofHandler, sym::Bool)
    ncells = getncells(dh.grid)
    n = ndofs_per_cell(dh)
    N = sym ? div(n*(n+1), 2) * ncells : n^2 * ncells
    N += ndofs(dh) # always add the diagonal elements
    I = Int[]; sizehint!(I, N)
    J = Int[]; sizehint!(J, N)
    global_dofs = zeros(Int, n)
    for element_id in 1:ncells
        celldofs!(global_dofs, dh, element_id)
        @inbounds for j in 1:n, i in 1:n
            dofi = global_dofs[i]
            dofj = global_dofs[j]
            sym && (dofi > dofj && continue)
            push!(I, dofi)
            push!(J, dofj)
        end
    end
    for d in 1:ndofs(dh)
        push!(I, d)
        push!(J, d)
    end
    V = zeros(length(I))
    K = sparse(I, J, V)
    return K
end


WriteVTK.vtk_grid(filename::AbstractString, dh::DofHandler) = vtk_grid(filename, dh.grid)

# Exports the FE field `u` to `vtkfile`
function WriteVTK.vtk_point_data(vtkfile, dh::DofHandler, u::Vector)
    offset = 0
    for i in 1:length(dh.field_names)
        ndim_field = dh.dof_dims[i]
        space_dim = ndim_field == 2 ? 3 : ndim_field
        data = zeros(space_dim, getnnodes(dh.grid))
        for j in 1:size(dh.dofs_nodes, 2)
            for k in 1:ndim_field
                data[k, j] = u[dh.dofs_nodes[k + offset, j]]
            end
        end
        vtk_point_data(vtkfile, data, string(dh.field_names[i]))
        offset += ndim_field
    end
    return vtkfile
end

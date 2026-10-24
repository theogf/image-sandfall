using GLMakie
using LinearAlgebra
using Colors
using Random
using FileIO

@enum CellType Empty Sand Block

struct Cell
  type::CellType
  color::RGB{Float64}
end
to_rgb((; color)::Cell) = color

Cell() = Cell(Empty, RGB(1.0, 1.0, 1.0))
block_cell() = Cell(Block, RGB(0.0, 0.0, 0.0))
Base.isempty((;type)::Cell) = type == Empty
isbusy((; type)::Cell) = type in (Sand, Block)

n = 100
img = rand(RGB{Float64}, n, n)
file =  "wat.jpg"
img = load(file)
nrows, ncols = size(img)

top_offset = 30
block_width = 1
grid = [Cell() for i in 1:(nrows + top_offset + block_width), j in 1:ncols]


# Initialization
for j in 1:size(grid, 2)
  for i in 1:size(img, 1)
    grid[i + top_offset, j] = Cell(Sand, img[i,j])
  end
  if !(div(ncols, 3) < j < 2 * div(ncols, 3))
    grid[end, j] = block_cell()
  end
end

function update!(grid::Matrix{Cell})
  for (i, row) in Iterators.reverse(enumerate(eachrow(grid)))
    for (j, cell) in shuffle(collect(enumerate(row)))
      cell.type in (Block, Empty) && continue
      row_below = mod1(i+1, size(grid, 1))
      cell_below = grid[row_below, j]
      if isempty(cell_below)
        grid[row_below, j] = cell
        grid[i, j] = Cell()
        continue
      end
      left = isone(j) ? nothing : j - 1
      right = j == size(grid, 2) ? nothing : j + 1
      options = filter((left, right)) do side
         isnothing(side) && return false
         diag_cell = grid[row_below, side]
         isempty(diag_cell)
      end
      isempty(options) && continue
      fall_side = rand(options)
      grid[row_below, fall_side] = cell
      grid[i, j] = Cell()
    end
  end
  grid
end

fig = Figure()
t = Observable(0)
colors = Observable(rotr90(to_rgb.(grid)))
on(t) do _
  update!(grid)
  @info "update"
  colors[] = rotr90(to_rgb.(grid))
end
ax = Axis(fig[1,1])
image!(ax, colors)
display(fig)
while true
 t[] += 1
end

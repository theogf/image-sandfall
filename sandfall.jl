using GLMakie
using Colors
using Random
using FileIO

@enum CellType Empty Sand Block

struct Cell
  type::CellType
  color::RGBf
end
to_rgb((; color)::Cell) = color

const EMPTY_CELL = Cell(Empty, RGBf(1, 1, 1))
Cell() = EMPTY_CELL
block_cell() = Cell(Block, RGBf(0, 0, 0))
Base.isempty((; type)::Cell) = type == Empty

const file = "wat.jpg"
const img = load(file)
const nrows, ncols = size(img)

const top_offset = 30
const block_width = 1
const initial_gap = false # set to false to start with a full floor of blocks, without the gap
const block_removal_interval = 200 # ticks
const blocks_removed_per_interval = 20
const grid = fill(Cell(), nrows + top_offset + block_width, ncols)

# Initialization
for j in 1:size(grid, 2)
  for i in 1:size(img, 1)
    grid[i + top_offset, j] = Cell(Sand, img[i, j])
  end
  if !initial_gap || !(div(ncols, 3) < j < 2 * div(ncols, 3))
    grid[end, j] = block_cell()
  end
end

function update!(grid::Matrix{Cell}, perm::Vector{Int})
  nr, nc = size(grid)
  @inbounds for i in nr:-1:1
    row_below = mod1(i + 1, nr)
    randperm!(perm) # random column order, without allocating
    for j in perm
      cell = grid[i, j]
      cell.type == Sand || continue
      if isempty(grid[row_below, j])
        grid[row_below, j] = cell
        grid[i, j] = Cell()
        continue
      end
      left = j > 1 && isempty(grid[row_below, j - 1])
      right = j < nc && isempty(grid[row_below, j + 1])
      (left || right) || continue
      fall_side = if left && right
        rand(Bool) ? j - 1 : j + 1
      else
        left ? j - 1 : j + 1
      end
      grid[row_below, fall_side] = cell
      grid[i, j] = Cell()
    end
  end
  grid
end

# Turn `n` randomly chosen block cells into empty cells
function remove_blocks!(grid::Matrix{Cell}, n::Int)
  blocks = findall(cell -> cell.type == Block, grid)
  for idx in Iterators.take(shuffle!(blocks), n)
    grid[idx] = Cell()
  end
  grid
end

# In-place equivalent of `buffer .= rotr90(to_rgb.(grid))`
function fill_colors!(buffer::Matrix{RGBf}, grid::Matrix{Cell})
  nr = size(grid, 1)
  @inbounds for j in axes(grid, 2), i in axes(grid, 1)
    buffer[j, nr - i + 1] = to_rgb(grid[i, j])
  end
  buffer
end

const perm = collect(1:size(grid, 2))
const colors = Observable(fill_colors!(Matrix{RGBf}(undef, reverse(size(grid))), grid))

const t = Observable(0) # number of simulation steps

fig = Figure()
Label(fig[0, 1], lift(t -> "t = $t", t); tellwidth = false)
ax = Axis(fig[1, 1]; aspect = DataAspect())
hidedecorations!(ax)
hidespines!(ax)
image!(ax, colors; interpolate = false)
tightlimits!(ax)

# Advance the simulation once per rendered frame
on(events(fig).tick) do _
  t[] += 1
  # With the initial gap, also remove blocks on the very first step
  if t[] % block_removal_interval == 0 || (initial_gap && t[] == 1)
    remove_blocks!(grid, blocks_removed_per_interval)
  end
  update!(grid, perm)
  fill_colors!(colors[], grid)
  notify(colors)
end

screen = display(fig)
wait(screen)

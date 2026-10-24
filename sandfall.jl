using GLMakie
using Colors
using Colors: N0f8
using Random
using FileIO

@enum CellType::UInt8 Empty Sand Block

const EMPTY_COLOR = RGB{N0f8}(1, 1, 1)
const BLOCK_COLOR = RGB{N0f8}(0, 0, 0)

const file = "sand-dunes.jpg"
const img = load(file)
const nrows, ncols = size(img)

const top_offset = 50
const block_width = 1
const initial_gap = false # set to false to start with a full floor of blocks, without the gap
const block_removal_interval = 200 # ticks
const blocks_removed_fraction = 1 / 30 # of the number of columns
const blocks_removed_per_interval = max(1, round(Int, blocks_removed_fraction * ncols))

# The state is stored in display orientation: `kinds[x, y]` and `pixels[x, y]`,
# with y = 1 the bottom row. `pixels` is shown directly by the image plot.
const ny = nrows + top_offset + block_width
const kinds = fill(Empty, ncols, ny)
const pixels = fill(EMPTY_COLOR, ncols, ny)

# Initialization
for x in 1:ncols
  for i in 1:nrows
    y = ny - (i + top_offset) + 1
    kinds[x, y] = Sand
    pixels[x, y] = img[i, x]
  end
  if !initial_gap || !(div(ncols, 3) < x < 2 * div(ncols, 3))
    kinds[x, 1] = Block
    pixels[x, 1] = BLOCK_COLOR
  end
end

function update!(kinds::Matrix{CellType}, pixels::Matrix{RGB{N0f8}})
  nx, ny = size(kinds)
  @inbounds for y in 1:ny
    below = y == 1 ? ny : y - 1
    # Visit the columns from a random start in a random direction: this avoids
    # a left/right bias for two random numbers per row instead of a full shuffle
    step = rand(Bool) ? 1 : -1
    x = rand(1:nx)
    for _ in 1:nx
      x += step
      x = x > nx ? 1 : x < 1 ? nx : x
      kinds[x, y] == Sand || continue
      if kinds[x, below] == Empty
        target = x
      else
        left = x > 1 && kinds[x - 1, below] == Empty
        right = x < nx && kinds[x + 1, below] == Empty
        (left || right) || continue
        target = if left && right
          rand(Bool) ? x - 1 : x + 1
        else
          left ? x - 1 : x + 1
        end
      end
      kinds[target, below] = Sand
      pixels[target, below] = pixels[x, y]
      kinds[x, y] = Empty
      pixels[x, y] = EMPTY_COLOR
    end
  end
  kinds
end

# Turn `n` randomly chosen block cells into empty cells
function remove_blocks!(kinds::Matrix{CellType}, pixels::Matrix{RGB{N0f8}}, n::Int)
  blocks = findall(==(Block), kinds)
  for idx in Iterators.take(shuffle!(blocks), n)
    kinds[idx] = Empty
    pixels[idx] = EMPTY_COLOR
  end
  kinds
end

const colors = Observable(pixels)

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
  # With a full floor, also remove blocks on the very first step
  if t[] % block_removal_interval == 0 || (!initial_gap && t[] == 1)
    remove_blocks!(kinds, pixels, blocks_removed_per_interval)
  end
  update!(kinds, pixels)
  notify(colors)
end

screen = display(fig)
wait(screen)

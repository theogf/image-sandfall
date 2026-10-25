using GLMakie
using Colors
using Colors: N0f8
using Random
using FileIO
using VideoIO

@enum CellType::UInt8 Empty Sand Block
@enum Direction Down Up Left Right

const EMPTY_COLOR = RGB{N0f8}(1, 1, 1)
const BLOCK_COLOR = RGB{N0f8}(0, 0, 0)

const file = "mario.jpg"
const use_webcam = true # take the image from the webcam instead of `file`; press space to retake it
const mirror_webcam = true

# Take one picture with the first camera (/dev/video0)
function capture_webcam(; attempts = 3)
  # Opening the camera occasionally fails while the device is still busy
  cam = nothing
  for k in 1:attempts
    try
      cam = VideoIO.opencamera()
      break
    catch
      k == attempts && rethrow()
      sleep(0.5)
    end
  end
  for _ in 1:10 # skip the first frames while the camera adjusts its exposure
    read(cam)
  end
  frame = read(cam)
  close(cam)
  return mirror_webcam ? reverse(frame; dims = 2) : collect(frame)
end

const img = use_webcam ? capture_webcam() : load(file)
const nrows, ncols = size(img)

const offset = 50 # empty cells between the image and the border, on every side
const block_width = 1
const initial_gap = false # set to false to start with full borders of blocks, without the gaps
const block_removal_interval = 200 # ticks
const blocks_removed_fraction = 1 / 30 # of the number of columns
const blocks_removed_per_interval = max(1, round(Int, blocks_removed_fraction * ncols))
const fps = 60

# The state is stored in display orientation: `kinds[x, y]` and `pixels[x, y]`,
# with y = 1 the bottom row. `pixels` is shown directly by the image plot.
# The grid wraps around in both directions, so the border rows at the bottom are
# shared between the bottom and the top, and the border columns on the left are
# shared between the left and the right.
const nx = ncols + 2 * offset + block_width
const ny = nrows + 2 * offset + block_width
const kinds = fill(Empty, nx, ny)
const pixels = fill(EMPTY_COLOR, nx, ny)

# Initialization
in_gap(i, n) = initial_gap && div(n, 3) < i < 2 * div(n, 3)
function init!(kinds, pixels, img)
  size(img) == (nrows, ncols) || error("the image must stay $(nrows)x$(ncols), got $(size(img))")
  fill!(kinds, Empty)
  fill!(pixels, EMPTY_COLOR)
  for j in 1:ncols, i in 1:nrows
    x = block_width + offset + j
    y = ny - offset - i + 1
    kinds[x, y] = Sand
    pixels[x, y] = img[i, j]
  end
  for x in 1:nx, y in 1:ny
    if (y <= block_width && !in_gap(x, nx)) || (x <= block_width && !in_gap(y, ny))
      kinds[x, y] = Block
      pixels[x, y] = BLOCK_COLOR
    end
  end
  kinds
end
init!(kinds, pixels, img)

# View of `A` in which gravity pulls towards lower second indices, like `Down` does for `A`
function oriented(A::AbstractMatrix, gravity::Direction)
  gravity == Down && return A
  gravity == Up && return view(A, :, size(A, 2):-1:1)
  gravity == Left && return PermutedDimsArray(A, (2, 1))
  return PermutedDimsArray(view(A, size(A, 1):-1:1, :), (2, 1))
end

update!(kinds, pixels, gravity::Direction) =
  fall!(oriented(kinds, gravity), oriented(pixels, gravity))

# One step of the simulation with gravity pulling towards lower `y`
function fall!(kinds::AbstractMatrix{CellType}, pixels::AbstractMatrix)
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
        x_left = x == 1 ? nx : x - 1
        x_right = x == nx ? 1 : x + 1
        left = kinds[x_left, below] == Empty
        right = kinds[x_right, below] == Empty
        (left || right) || continue
        target = if left && right
          rand(Bool) ? x_left : x_right
        else
          left ? x_left : x_right
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
const gravity = Observable(Down)
const arrow_directions = Dict(
  Keyboard.down => Down, Keyboard.up => Up, Keyboard.left => Left, Keyboard.right => Right,
)

fig = Figure()
Label(fig[0, 1], lift((t, g) -> "t = $t    gravity: $(lowercase(string(g)))", t, gravity);
  tellwidth = false)
ax = Axis(fig[1, 1]; aspect = DataAspect())
hidedecorations!(ax)
hidespines!(ax)
image!(ax, colors; interpolate = false)
tightlimits!(ax)

# Change the direction of gravity with the arrow keys, retake the picture with space
on(events(fig).keyboardbutton) do event
  event.action == Keyboard.press || return
  if haskey(arrow_directions, event.key)
    gravity[] = arrow_directions[event.key]
  elseif event.key == Keyboard.space && use_webcam
    init!(kinds, pixels, capture_webcam())
    t[] = 0
    notify(colors)
  end
end

# Advance the simulation once per rendered frame
on(events(fig).tick) do _
  t[] += 1
  # With full borders, also remove blocks on the very first step
  if t[] % block_removal_interval == 0 || (!initial_gap && t[] == 1)
    remove_blocks!(kinds, pixels, blocks_removed_per_interval)
  end
  update!(kinds, pixels, gravity[])
  notify(colors)
end

GLMakie.activate!(; framerate = fps) # GLMakie renders at 30 fps by default
screen = display(fig)
wait(screen)

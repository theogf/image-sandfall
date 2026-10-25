using GLMakie
using Colors
using Colors: N0f8
using Random
using FileIO
using VideoIO

@enum CellType::UInt8 Empty Sand Block Obstacle # obstacles only exist during the physics step
@enum Direction Down Up Left Right

const EMPTY_COLOR = RGB{N0f8}(1, 1, 1)
const BLOCK_COLOR = RGB{N0f8}(0, 0, 0)

const file = "mario.jpg"
const use_webcam = true # take the image from the webcam instead of `file`; press space to retake it
const mirror_webcam = true
const live_colors = true # with the webcam, each grain shows the live colour of the pixel it started as
const live = use_webcam && live_colors

# Open the first camera (/dev/video0) and let it adjust its exposure
function open_camera(; attempts = 3)
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
  cam
end

function read_frame(cam)
  frame = read(cam)
  return mirror_webcam ? reverse(frame; dims = 2) : collect(frame)
end

# Take one picture with the camera
function capture_webcam()
  cam = open_camera()
  frame = read_frame(cam)
  close(cam)
  frame
end

# For live colours, a background task keeps the camera open and stores its latest frame
const frame_lock = ReentrantLock()
const latest = Ref{Matrix{RGB{N0f8}}}()
const camera_running = Threads.Atomic{Bool}(true)
latest_frame() = @lock frame_lock latest[]

function start_camera!()
  cam = open_camera()
  latest[] = read_frame(cam)
  # Reading a frame blocks until the camera delivers it, so do it on another thread
  # than the rendering
  Threads.@spawn :default begin
    try
      while camera_running[]
        frame = read_frame(cam)
        @lock frame_lock latest[] = frame
      end
    catch e
      @error "The webcam reader stopped" exception = (e, catch_backtrace())
    finally
      close(cam)
    end
  end
  latest[]
end

const img = !use_webcam ? load(file) : live ? start_camera!() : capture_webcam()
const nrows, ncols = size(img)

# Empty cells between the image and the border on each side, as a fraction of the
# image width (left and right) and height (top and bottom)
const offset_fraction = 0.025
const offset_x = round(Int, offset_fraction * ncols)
const offset_y = round(Int, offset_fraction * nrows)
const block_width = 1
const initial_gap = false # set to false to start with full borders of blocks, without the gaps
const block_removal_interval = 200 # ticks
const blocks_removed_fraction = 1 / 30 # of the number of columns
const blocks_removed_per_interval = max(1, round(Int, blocks_removed_fraction * ncols))
const fps = 60
const sort_passes = 4 # passes per frame reordering neighbouring grains like in the image, 0 disables
const sort_window = 10 # only grains from pixels at most this far apart in the image are reordered
const reassemble_time = 1.5 # seconds of holding R for the grains to fly all the way home
const reassemble_stagger = 0.7 # part of that time over which the rows of the image start one after the other
const mouse_radius = round(Int, 0.05 * min(nrows, ncols)) # radius of the round part of the drop around the cursor
const drop_length = 2.5 # distance from the cursor to the tip of the drop, in radii

# The state is stored in display orientation: `kinds[x, y]` and `origins[x, y]`,
# with y = 1 the bottom row. `origins` holds, for each grain, the row and column of
# the image pixel it started as, so a grain keeps the colour of that pixel
# wherever it moves. `pixels` is drawn from them and shown by the image plot.
# The grid wraps around in both directions, so the border rows at the bottom are
# shared between the bottom and the top, and the border columns on the left are
# shared between the left and the right.
const nx = ncols + 2 * offset_x + block_width
const ny = nrows + 2 * offset_y + block_width
const kinds = fill(Empty, nx, ny)
const origins = zeros(UInt32, nx, ny)
const pixels = fill(EMPTY_COLOR, nx, ny)
const source = Ref(img) # image the grains take their colours from, without live colours

# The row and column of a grain's origin are packed in one integer, so that comparing
# the rows or the columns of two grains is cheap
pack_origin(i, j) = UInt32(j) << 16 | UInt32(i)
origin_row(o::UInt32) = Int(o & 0xffff)
origin_col(o::UInt32) = Int(o >> 16)
# Grid position of a grain's original pixel
home_x(o) = block_width + offset_x + origin_col(o)
home_y(o) = ny - offset_y - origin_row(o) + 1

# Put every grain back at its original position
function place_home!(kinds, origins)
  replace!(kinds, Sand => Empty)
  for j in 1:ncols, i in 1:nrows
    o = pack_origin(i, j)
    kinds[home_x(o), home_y(o)] = Sand
    origins[home_x(o), home_y(o)] = o
  end
  kinds
end

# Initialization
in_gap(i, n) = initial_gap && div(n, 3) < i < 2 * div(n, 3)
function init!(kinds, origins)
  fill!(kinds, Empty)
  place_home!(kinds, origins)
  for x in 1:nx, y in 1:ny
    if (y <= block_width && !in_gap(x, nx)) || (x <= block_width && !in_gap(y, ny))
      kinds[x, y] = Block
    end
  end
  kinds
end
init!(kinds, origins)

# View of `A` in which gravity pulls towards lower second indices, like `Down` does for `A`
function oriented(A::AbstractMatrix, gravity::Direction)
  gravity == Down && return A
  gravity == Up && return view(A, :, size(A, 2):-1:1)
  gravity == Left && return PermutedDimsArray(A, (2, 1))
  return PermutedDimsArray(view(A, size(A, 1):-1:1, :), (2, 1))
end

update!(kinds, origins, gravity::Direction) =
  fall!(oriented(kinds, gravity), oriented(origins, gravity))

# One step of the simulation with gravity pulling towards lower `y`
function fall!(kinds::AbstractMatrix{CellType}, origins::AbstractMatrix{UInt32})
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
      origins[target, below] = origins[x, y]
      kinds[x, y] = Empty
    end
  end
  kinds
end

# Swap neighbouring grains that are in the wrong order compared to the image, so that
# the image slowly reappears in the shape of the pile. Only grains from nearby pixels
# are swapped: a grain far from its neighbours in the image would otherwise travel
# across the whole pile. Only every other pair is compared, starting at `parity`, so
# that no grain takes part in two swaps.
function sort_grains!(kinds::Matrix{CellType}, origins::Matrix{UInt32}, parity::Int)
  nx, ny = size(kinds)
  @inbounds for y in 1:ny, x in (1 + parity):2:(nx - 1)
    a, b = origins[x, y], origins[x + 1, y]
    if kinds[x, y] == Sand && kinds[x + 1, y] == Sand && 0 < origin_col(a) - origin_col(b) <= sort_window &&
        abs(origin_row(a) - origin_row(b)) <= sort_window
      origins[x, y], origins[x + 1, y] = b, a
    end
  end
  # The grain at y + 1 is above the one at y, so it should come from a higher row
  @inbounds for y in (1 + parity):2:(ny - 1), x in 1:nx
    a, b = origins[x, y + 1], origins[x, y]
    if kinds[x, y] == Sand && kinds[x, y + 1] == Sand && 0 < origin_row(a) - origin_row(b) <= sort_window &&
        abs(origin_col(a) - origin_col(b)) <= sort_window
      origins[x, y + 1], origins[x, y] = b, a
    end
  end
  kinds
end

# Turn `n` randomly chosen block cells into empty cells
function remove_blocks!(kinds::Matrix{CellType}, n::Int)
  blocks = findall(==(Block), kinds)
  for idx in Iterators.take(shuffle!(blocks), n)
    kinds[idx] = Empty
  end
  kinds
end

# Colour every cell: each grain shows the pixel of `image` it started as
function render!(pixels::Matrix{RGB{N0f8}}, kinds::Matrix{CellType}, origins::Matrix{UInt32},
    image::AbstractMatrix)
  @inbounds for i in eachindex(pixels, kinds, origins)
    kind = kinds[i]
    pixels[i] = if kind == Sand
      image[origin_row(origins[i]), origin_col(origins[i])]
    else
      kind == Block ? BLOCK_COLOR : EMPTY_COLOR
    end
  end
  pixels
end
current_image() = live ? latest_frame() : source[]

# While R is held, every grain flies in a straight line back to its original position,
# and when R is released before they arrive, they land where they are. The grid is
# left untouched during the flight: the grains are drawn directly in `pixels`.
# The image is rebuilt from its bottom, relative to gravity: each grain starts flying
# after a delay that grows with the height of its original pixel, so that the rows
# of the image arrive one after the other.
mutable struct Flight
  progress::Float64 # from 0 to 1, when all the grains are home
  last_time::Float64
  const xs::Vector{Int32}
  const ys::Vector{Int32}
  const origins::Vector{UInt32}
  const delays::Vector{Float32} # progress at which each grain starts flying
end
const flight = Ref{Union{Nothing, Flight}}(nothing)
const assembled = Ref(false) # the grains arrived home while R is still held

function start_flight(kinds, origins, gravity::Direction)
  grains = findall(==(Sand), kinds)
  up = drop_axes(gravity)[1]
  heights = [home_x(o) * up[1] + home_y(o) * up[2] for o in origins[grains]]
  low, high = extrema(heights)
  delays = [Float32(reassemble_stagger * (h - low) / max(1, high - low)) for h in heights]
  Flight(0.0, time(), [Int32(g[1]) for g in grains], [Int32(g[2]) for g in grains], origins[grains], delays)
end

# How far the `k`-th grain of `f` is on its way home, eased in and out
@inline function eased(f::Flight, k)
  p = clamp((Float32(f.progress) - f.delays[k]) / Float32(1 - reassemble_stagger), 0f0, 1f0)
  p^2 * (3 - 2p)
end

# Cell of the `k`-th grain of `f`, a fraction `e` of the way home
@inline function flight_position(f::Flight, k, e)
  o = f.origins[k]
  x = unsafe_trunc(Int, f.xs[k] + e * (home_x(o) - f.xs[k]) + 0.5f0)
  y = unsafe_trunc(Int, f.ys[k] + e * (home_y(o) - f.ys[k]) + 0.5f0)
  x, y
end

function render_flight!(pixels::Matrix{RGB{N0f8}}, kinds::Matrix{CellType}, f::Flight,
    image::AbstractMatrix)
  @inbounds for i in eachindex(pixels, kinds)
    pixels[i] = kinds[i] == Block ? BLOCK_COLOR : EMPTY_COLOR
  end
  # The grains that arrived are drawn last, so that the rebuilt rows look clean
  @inbounds for arrived in (false, true), k in eachindex(f.origins)
    e = eased(f, k)
    (e == 1) == arrived || continue
    x, y = flight_position(f, k, e)
    o = f.origins[k]
    pixels[x, y] = image[origin_row(o), origin_col(o)]
  end
  pixels
end

# Put the flying grains in the grid where they are. Grains can overlap during the
# flight: a grain whose cell is already taken goes to the first empty cell above it,
# against gravity, or in the closest line beside it when its line is full.
function land!(kinds::Matrix{CellType}, origins::Matrix{UInt32}, f::Flight, gravity::Direction)
  up = drop_axes(gravity)[1]
  replace!(kinds, Sand => Empty)
  # `next_empty[i]` leads from cell `i` towards the first empty cell above it, and
  # `line_right[l]` and `line_left[l]` from line `l` towards the closest lines on
  # either side that are not full. Lines are columns, or rows for horizontal gravity.
  next_empty = [kinds[i] == Empty ? i : next_cell(kinds, i, up) for i in eachindex(kinds)]
  nlines = up[1] == 0 ? size(kinds, 1) : size(kinds, 2)
  line_right = collect(1:nlines)
  line_left = collect(1:nlines)
  # The grains that arrived land first, so that the rebuilt rows stay in place
  @inbounds for arrived in (true, false), k in eachindex(f.origins)
    e = eased(f, k)
    (e == 1) == arrived || continue
    x, y = flight_position(f, k, e)
    i = find_landing(kinds, next_empty, line_right, line_left, x, y, up[1] == 0)
    kinds[i] = Sand
    origins[i] = f.origins[k]
    next_empty[i] = next_cell(kinds, i, up)
  end
  kinds
end

# Linear index of the cell next to cell `i` in `direction`, one of the four axes,
# around the grid
@inline function next_cell(kinds, i, direction)
  nx, n = size(kinds, 1), length(kinds)
  direction == (0, 1) && return i + nx > n ? i + nx - n : i + nx
  direction == (0, -1) && return i - nx < 1 ? i - nx + n : i - nx
  direction == (1, 0) && return i % nx == 0 ? i - nx + 1 : i + 1
  return (i - 1) % nx == 0 ? i + nx - 1 : i - 1
end

# Empty cell closest to (x, y) upwards, in its line or the closest one beside it
function find_landing(kinds, next_empty, line_right, line_left, x, y, vertical)
  nx, ny = size(kinds)
  line, nlines = vertical ? (x, nx) : (y, ny)
  while true
    right = follow!(line_right, line)
    left = follow!(line_left, line)
    l = mod(right - line, nlines) <= mod(line - left, nlines) ? right : left
    j = vertical ? l + (y - 1) * nx : x + (l - 1) * nx
    landing = empty_above!(next_empty, j, vertical ? ny : nx)
    landing == 0 || return landing
    # This line is full: skip it from now on
    line_right[l] = mod1(l + 1, nlines)
    line_left[l] = mod1(l - 1, nlines)
  end
end

# Follow the `pointers` from `i` to the end of the path, shortening it on the way
function follow!(pointers, i)
  root = i
  while pointers[root] != root
    root = pointers[root]
  end
  while i != root
    after = pointers[i]
    pointers[i] = root
    i = after
  end
  root
end

# Follow `next_empty` from cell `i` to an empty cell, shortening the path for the next
# searches. Returns 0 when there is none within `max_steps`.
function empty_above!(next_empty, i, max_steps)
  root = i
  for _ in 1:max_steps
    next_empty[root] == root && break
    root = next_empty[root]
  end
  next_empty[root] == root || return 0
  while i != root
    after = next_empty[i]
    next_empty[i] = root
    i = after
  end
  root
end

# Grains inside a drop shape around the mouse cursor are pushed out of it. The round
# part of the drop is centred on the cursor, and its tip points against gravity.
# Each offset in the drop comes with the direction it is pushed in, as an index in
# `DIRECTIONS`, and the offsets go from the edge inwards.
const DIRECTIONS = ((1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1), (0, -1), (1, -1))
direction_index(vx, vy) = mod(round(Int, atan(vy, vx) / (pi / 4)), 8) + 1

# Unit vectors towards the tip of the drop (`up`) and across it (`side`)
function drop_axes(gravity::Direction)
  up = Dict(Down => (0, 1), Up => (0, -1), Left => (1, 0), Right => (-1, 0))[gravity]
  up, (up[2], -up[1])
end

function drop_offsets(gravity::Direction)
  r = mouse_radius
  tip = drop_length * r
  up, side = drop_axes(gravity)
  # The sides of the tip are tangent to the circle, at a height `r^2 / tip`
  sin_a = r / tip
  cos_a = sqrt(1 - sin_a^2)
  offsets = Tuple{Int, Int, Int, Float64}[] # offset, direction, depth inside the drop
  for dx in -ceil(Int, tip):ceil(Int, tip), dy in -ceil(Int, tip):ceil(Int, tip)
    u = dx * up[1] + dy * up[2]  # height towards the tip
    v = dx * side[1] + dy * side[2]
    if u >= r^2 / tip && u <= tip
      # In the tip: pushed out through the closest side
      depth = (tip - u) * sin_a - abs(v) * cos_a # distance to the closest side
      depth >= 0 || continue
      dv, du = sign(v) * cos_a, sin_a
    elseif u^2 + v^2 <= r^2
      # In the round part: pushed away from the centre
      depth = r - hypot(u, v)
      dv, du = (u == v == 0) ? (0.0, 1.0) : (v, u)
    else
      continue
    end
    vx = dv * side[1] + du * up[1]
    vy = dv * side[2] + du * up[2]
    push!(offsets, (dx, dy, direction_index(vx, vy), depth))
  end
  sort!(offsets; by = last)
  [(dx, dy, d) for (dx, dy, d, _) in offsets]
end
const push_offsets = Dict(g => drop_offsets(g) for g in instances(Direction))

# Which offsets are in the drop, as a matrix centred on the cursor
const drop_extent = ceil(Int, drop_length * mouse_radius) + 1
const drop_masks = Dict(g => begin
  mask = falses(2 * drop_extent + 1, 2 * drop_extent + 1)
  for (dx, dy, _) in push_offsets[g]
    mask[dx + drop_extent + 1, dy + drop_extent + 1] = true
  end
  mask
end for g in instances(Direction))
in_drop(mask, dx, dy) = max(abs(dx), abs(dy)) <= drop_extent && mask[dx + drop_extent + 1, dy + drop_extent + 1]

# Outline of the drop, relative to the centre of its round part
function drop_outline(gravity::Direction)
  r = mouse_radius
  tip = drop_length * r
  up, side = drop_axes(gravity)
  # From the tip, around the round part between the points where the sides touch it
  phi = acos(r / tip)
  points = [(0.0, tip); [(r * sin(a), r * cos(a)) for a in range(phi, 2pi - phi; length = 64)]; (0.0, tip)]
  [Point2f(v * side[1] + u * up[1], v * side[2] + u * up[2]) for (v, u) in points]
end
const drop_outlines = Dict(g => drop_outline(g) for g in instances(Direction))

# Turn the cells of the drop around (cx, cy) that are of kind `from` into `to`
function set_drop!(kinds::Matrix{CellType}, cx::Int, cy::Int, offsets::Vector{NTuple{3, Int}},
    from::CellType, to::CellType)
  nx, ny = size(kinds)
  @inbounds for (dx, dy, _) in offsets
    x, y = wrap(cx + dx, nx), wrap(cy + dy, ny)
    kinds[x, y] == from && (kinds[x, y] = to)
  end
  kinds
end

# Wrap an index around the grid, for indices less than one grid size outside of it
wrap(i, n) = i < 1 ? i + n : i > n ? i - n : i

const push_line = Int[] # cells of the line of grains being pushed, as linear indices
# Longest line of grains that can be pushed, short enough not to wrap around the grid
# back into the drop
const max_push = min(nx, ny) - 2 * drop_extent - 2
# When the way out is full, try the other directions, closest first
const PUSH_TURNS = (0, 1, -1, 2, -2, 3, -3, 4)

# Move every grain in the drop around (cx, cy) out of it, to the first cell past its
# edge in the grain's direction. The grains already there are pushed along the line,
# up to the first empty cell, jumping over the blocks of the borders.
function push_away!(kinds::Matrix{CellType}, origins::Matrix{UInt32}, cx::Int, cy::Int,
    offsets::Vector{NTuple{3, Int}}, mask::BitMatrix)
  line = push_line
  @inbounds for (dx, dy, d) in offsets
    x, y = wrap(cx + dx, size(kinds, 1)), wrap(cy + dy, size(kinds, 2))
    kinds[x, y] == Sand || continue
    found = false
    for turn in PUSH_TURNS
      found = push_line!(line, kinds, mask, x, y, dx, dy, DIRECTIONS[mod1(d + turn, 8)])
      found && break
    end
    found || continue
    # Shift the grains along the line by one cell, and put this grain at its start
    for k in length(line):-1:2
      kinds[line[k]] = Sand
      origins[line[k]] = origins[line[k - 1]]
    end
    kinds[line[1]] = Sand
    origins[line[1]] = origins[x, y]
    kinds[x, y] = Empty
  end
  kinds
end

# Fill `line` with the cells from the edge of the drop to the first empty cell, going
# from (x, y), at offset (dx, dy) in the drop, in `direction`, without the blocks.
# Returns whether there is an empty cell close enough.
function push_line!(line, kinds, mask, x, y, dx, dy, (sx, sy))
  nx, ny = size(kinds)
  steps = 1
  while in_drop(mask, dx + steps * sx, dy + steps * sy)
    steps += 1
  end
  empty!(line)
  lx, ly = wrap(x + steps * sx, nx), wrap(y + steps * sy, ny)
  @inbounds for _ in 1:max_push
    kind = kinds[lx, ly]
    kind == Block || push!(line, lx + (ly - 1) * nx)
    kind == Empty && return true
    lx, ly = wrap(lx + sx, nx), wrap(ly + sy, ny)
  end
  false
end

const colors = Observable(render!(pixels, kinds, origins, current_image()))

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
limits!(ax, 0, nx, 0, ny)

# The possible actions, below the image. Non-breaking spaces inside each action, so
# that the lines only wrap between actions.
const help = join([replace(action, ' ' => '\u00a0') for action in filter(!isempty, [
  "arrow keys: change gravity",
  "hold R: bring the pixels back home",
  use_webcam ? "space: retake the photo" : "",
  "mouse over the image: push the sand away",
])], "     ")
Label(fig[2, 1], help; fontsize = 13, color = :gray35, tellwidth = false, word_wrap = true)

# Grid cell under the mouse cursor, or `nothing` when it is not over the image
mouse_cell() = is_mouseinside(ax.scene) ? floor.(Int, mouseposition(ax.scene)) .+ 1 : nothing

# Outline of the drop around the cursor
const drop_line = lift(events(fig).mouseposition, gravity) do _, g
  cell = mouse_cell()
  cell === nothing && return [Point2f(NaN)]
  Ref(Point2f(cell .- 0.5)) .+ drop_outlines[g]
end
lines!(ax, drop_line; color = (:black, 0.6), linewidth = 1.5)

# Change the direction of gravity with the arrow keys, retake the picture with space
on(events(fig).keyboardbutton) do event
  event.action == Keyboard.press || return
  if haskey(arrow_directions, event.key)
    gravity[] = arrow_directions[event.key]
  elseif event.key == Keyboard.space && use_webcam
    live || (source[] = capture_webcam())
    flight[] = nothing
    assembled[] = false
    init!(kinds, origins)
    t[] = 0
    render!(pixels, kinds, origins, current_image())
    notify(colors)
  end
end

# Advance the simulation once per rendered frame
on(events(fig).tick) do _
  held = Keyboard.r in events(fig).keyboardstate
  # The grains arrived home while R is still held: keep showing the image
  if held && assembled[]
    render!(pixels, kinds, origins, current_image())
    notify(colors)
    return
  end
  # Holding R moves the grains home: no physics meanwhile
  if held
    f = flight[]
    f === nothing && (f = flight[] = start_flight(kinds, origins, gravity[]))
    now = time()
    f.progress = min(1.0, f.progress + (now - f.last_time) / reassemble_time)
    f.last_time = now
    if f.progress >= 1
      # They arrived: keep the image while R is held, the sand falls from it afterwards
      place_home!(kinds, origins)
      flight[] = nothing
      assembled[] = true
      render!(pixels, kinds, origins, current_image())
      notify(colors)
      return
    end
    render_flight!(pixels, kinds, f, current_image())
    notify(colors)
    return
  end
  # R was released before the grains arrived: they land where they are
  if flight[] !== nothing
    land!(kinds, origins, flight[], gravity[])
    flight[] = nothing
  end
  assembled[] = false
  t[] += 1
  # With full borders, also remove blocks on the very first step
  if t[] % block_removal_interval == 0 || (!initial_gap && t[] == 1)
    remove_blocks!(kinds, blocks_removed_per_interval)
  end
  # The drop around the cursor pushes the grains in it out, and the sand can't fall
  # into it: its empty cells are obstacles during the physics
  cell = mouse_cell()
  offsets = push_offsets[gravity[]]
  if cell !== nothing
    push_away!(kinds, origins, cell..., offsets, drop_masks[gravity[]])
    set_drop!(kinds, cell..., offsets, Empty, Obstacle)
  end
  update!(kinds, origins, gravity[])
  cell === nothing || set_drop!(kinds, cell..., offsets, Obstacle, Empty)
  for k in 1:sort_passes
    sort_grains!(kinds, origins, (t[] * sort_passes + k) % 2)
  end
  render!(pixels, kinds, origins, current_image())
  notify(colors)
end

GLMakie.activate!(; framerate = fps) # GLMakie renders at 30 fps by default
screen = display(fig)
wait(screen)
camera_running[] = false

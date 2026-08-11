# processorek Nevosolek (P4) and nad czerwonym lampa (P8) scene reconstruction

This document is the source-level reconstruction of the two standalone 3D
parts in VOODKA. It is intentionally more specific than the general
asset-format and porting notes. The original source is under
demoscene-absence-voodka-master/CODE; the modern implementation is under
port/core and port/platform. Line references below use the original TASM
files and named labels, so they remain useful even when generated includes
are regenerated.

## 1. What these scenes are

processorek Nevosolek (P4) and nad czerwonym lampa (P8) are not entries in the swiatynia city/torus ustep village (P2/P5) World table. They do not instantiate
objects from WORLD records, and their camera files are not the 48-byte World
camera format. Each part is a self-contained assembly program that combines:

1. compile-time vertex and face tables included from CODE/DATAS;
2. runtime texture/picture/sprite blobs loaded from vodka.dat;
3. an embedded face-material table, UV table, palette include, and animation
   constants;
4. a 36-byte-per-node camera path;
5. the shared engine routines for normals, rotation, painter sorting, and
   indexed triangle rasterization.

The scene is therefore defined by the part source plus its DATAS includes.
There is no single processorek Nevosolek (P4) or nad czerwonym lampa (P8) “world asset” that can be loaded independently.
The archive textures are raw indexed pixels; the DATAS files are raw
16-bit geometry; the source assembly is what assigns geometry to textures,
palette offsets, animation buffers, and camera placement.

Both parts render to a 320x200, 256-colour indexed framebuffer. The original
copies that framebuffer to VGA memory at the beginning of the next iteration
of the loop, then clears the drawing buffer. There is no z-buffer. Visible
faces are painter-sorted by a depth key and may also be rejected by a
screen-space winding test.

## 2. Shared representation and rendering contracts

### 2.1 Archive and raw asset boundaries

vodka.dat begins with 1000 pairs of 32-bit offset and size values. The
manifest index is the index used by the vodka macro; it is zero-based in the
reconstruction documentation. The relevant entries are:

| Index | Asset | Size and interpretation | Scene |
|---:|---|---|---|
| 24 | sw.inc | 44,032 bytes, 256x172 indexed texture | processorek Nevosolek (P4), nad czerwonym lampa (P8) |
| 25 | v_txr1.inc | 51,200 bytes, 256x200 indexed texture | processorek Nevosolek (P4) |
| 26 | proc.inc | 51,200 bytes, 256x200 indexed texture | processorek Nevosolek (P4) |
| 27 | metal.inc | 51,200 bytes, 256x200 indexed texture | processorek Nevosolek (P4), nad czerwonym lampa (P8) |
| 28 | logo_a.dat | 48,000 bytes, 15 frames of 64x50 | processorek Nevosolek (P4) |
| 29 | tull.inc | 64,000 bytes, 320x200 image | processorek Nevosolek (P4) |
| 30 | tull.pal | 768-byte 6-bit VGA palette | processorek Nevosolek (P4) |
| 70 | last.pal | 768-byte 6-bit VGA palette | nad czerwonym lampa (P8) |
| 71 | last.dat | 63,680 bytes, 320x199 image | nad czerwonym lampa (P8) |
| 73 | log.inc | 77,824 bytes, 19 frames of 64x64 | nad czerwonym lampa (P8) |
| 74 | trasa.dat | 106,704 bytes, 2,964 camera nodes | processorek Nevosolek (P4) |
| 75 | tr2.dat | 90,288 bytes, 2,508 camera nodes | nad czerwonym lampa (P8) |

Texture bytes are palette indices, not RGB values. processorek Nevosolek (P4) and nad czerwonym lampa (P8) use the same
sw.inc pixels but do not use the same embedded sw palette arrangement. processorek Nevosolek (P4)
includes sw.pal as the 64-colour processorek Nevosolek (P4) material source; nad czerwonym lampa (P8) includes a full base
palette in the recovered object. The port names the recovered versions
port/core/parts/sw.pal and port/core/parts/p8_sw.pal to prevent accidental
substitution. metal.pal is the same 64-colour chrome ramp in both parts.

The 16-bit DATAS files are also not archive files. A vertex include contains
N rows of dw x,y,z, six bytes per vertex. A face include contains M rows of
dw i0,i1,i2, six bytes per face. Coordinates and indices are signed/unsigned
16-bit values respectively. TASM includes these rows directly into the part
object file.

### 2.2 The three face-side tables

The part-local tables are parallel to the concatenated face list:

- con1/c1/c2/... contains three vertex indices per face. prepare converts
  each index to a byte offset by multiplying it by two.
- con2 contains the UV vertex indices used by ordinary textured faces. Its
  values address the local pos table, also in word-byte units.
- con3 contains one eight-byte material record per face:

  ~~~text
  dd texture_selector
  db colour_offset, plane_flag
  db visibility_flag, phong_flag
  ~~~

  colour_offset is added to every sampled texture index. plane_flag selects
  the precomputed projected UVs in pkt. visibility_flag enables the
  screen-space back-face test. phong_flag selects the normal-derived UVs
  instead of con2/pos.

The original source writes selectors into con3. The x64 port stores an
equivalent map index and resolves it through the selector-base table before
sampling. This distinction is architectural, not a scene-format change.

### 2.3 UVs, palettes, and the mapper

pos and pkt store U and V as 8.8 fixed-point words. After the face routine
reorders the words, the packed value is effectively:

~~~text
EDX = (U_fixed << 16) | V_fixed
u = (EDX >> 16) & 255
v = (EDX >> 24) & 255
texture_address = (v & 255) * 256 + (u & 255)
~~~

The mapper is deliberately 256 pixels wide even when an asset has fewer
than 256 rows. Both coordinates wrap through the 16-bit arithmetic. There is
no bilinear filtering, alpha, z comparison, or palette conversion in face.
A fetched index is incremented by the con3 colour offset and written to the
indexed framebuffer. A texel value of zero is only transparent in the
separate logo/sun sprite routines; it is an ordinary opaque index in face.

Palette values are VGA DAC values in the range 0..63. make_pal applies a
signed per-channel delta, clamps below zero and above 63, and writes a new
64-colour ramp. It is not RGB interpolation and does not operate on the
texture bytes.

### 2.4 Matrices, projection, culling, and sort

The shared sinus table contains signed Q15 values. Its index is a 1/1024-turn
angle: 256 is a quarter turn, 512 is a half turn, and the cosine table is
the sinus table plus 512 entries. prep_rot1 constructs the object matrix
ob1..ob9 from r_x/r_y/r_z. prep_rot2 constructs the camera matrix ca1..ca9
from cm_x/cm_y/cm_z. Each matrix product is a 32-bit multiply followed by
sar 15.

rotate first transforms the precomputed centre of every face through the
object matrix, camera matrix, and translation o_x/o_y/o_z. A face is
discarded if its centre is outside the part's x/y/z bounds. Its sort key is
the translated depth plus a part-specific constant. The face offset is stored
in draw_tab. Only after a face survives does rotate lazily project its three
vertices, using check to avoid projecting the same vertex repeatedly.

The projection is integer division, not floating point. The standard centre
is (160,100), and zoom is 160. The exact denominators and y signs differ
between processorek Nevosolek (P4) and nad czerwonym lampa (P8) and are documented below. The resulting coordinates are
signed screen-space values; face clips them during scan conversion.

bit_sort calls the generic radix/painter sorter in ENGINE. Neither scene has
per-pixel depth. The processorek Nevosolek (P4) show loop walks its sorted table backwards; nad czerwonym lampa (P8) walks
forwards. This traversal is part of the original implementation and must be
kept with the sorter’s key ordering to reproduce overlap.

face sorts the three vertices by y, computes 16.16 edge slopes, computes
16-bit UV slopes, clips the vertical span to rows 0..199, and fills one
scanline at a time. Horizontal middle-edge handling is selected by pom.
The source rasterizer writes directly to the indexed framebuffer and is
opaque. The port retains the same projected/cull/sort decisions; its processorek Nevosolek (P4)
bounded C++ triangle helper is a compatibility implementation of the
assembly scan conversion, not a new material model.

## 3. processorek Nevosolek (P4): tunnel, plate, CPU detail, and chrome object

### 3.1 Composition and geometry inventory

processorek Nevosolek (P4) declares p_len = 567 vertices and f_len = 994 faces in
CODE/P4/P4.ASM near the file header. The concatenated geometry is:

| Segment | Vertices/faces | Source include | Runtime role | Material |
|---|---:|---|---|---|
| Base shape | 222 / 440 | VWS_1.INC / VWC_1.INC | large sw environment/tunnel shell and its repeated textured surface | sw.inc, offset 0 |
| Auxiliary plate | 81 / 158 | VWS_2.INC / VWC_2.INC | animated/rotated plate section; 14 of its faces switch to the plane path | v_txr1.inc, normally offset 128 |
| CPU/detail mesh | 8 / 12 | VWS_3.INC / VWC_3.INC | small processor/label detail on the plate | proc.inc, offset 144 |
| Chrome mesh | 256 / 384 | VWS_4.INC / VWC_4.INC | metallic/phong-shaded object(s) in the same shot | metal.inc, offset 192 |

The names “shape”, “src1”, “src2”, and “src3” are source-program names, not
file-format roles. The first 222 vertices are the stationary base shape.
The other three source tables are copied/rotated into s1, s2, and s3 before
each frame. The final scene is one concatenated face list, not four
independently submitted models.

processorek Nevosolek (P4)'s visible result is the textured concentric environment surrounding a
central plate/hero composition, with the small proc-marked component and
chrome/phong geometry appearing according to the camera path. The source
does not contain a scene graph or named object transforms; those relationships
are encoded by the concatenation offsets and con3 ranges.

### 3.2 Assembly-time layout and connectivity

processorek Nevosolek (P4) lays out the source data in this order:

~~~text
src1 = VWS_2 (81 vertices)
src2 = VWS_3 (8 vertices)
src3 = VWS_4 (256 vertices)
shape = VWS_1 (222 vertices)
s1 = 81*3 zero words
s2 = 8*3 zero words
s3 = 256*3 zero words

con1 = VWC_1 (440 faces)
c1   = VWC_2 (158 faces)
c2   = VWC_3 (12 faces)
c3   = VWC_4 (384 faces)
~~~

prepare doubles the indices in con1, halves all three source-coordinate
tables in place, and adds the base vertex count to c1 and the cumulative
base/source counts to c2 and c3. The result is that the first face group
addresses shape, while later groups address s1, s2, and s3. co_prepare then
adds the combined base/source offset to the c3 normal connectivity used by
n_calc.

This is an important distinction from an ordinary morph target: processorek Nevosolek (P4) does not
interpolate VWS_1 into VWS_2/3/4. It keeps VWS_1 as the fixed environment and
replaces the source-object buffers with a per-frame z-axis rotation and bob.
The “morph” terminology in inventory tools describes the shared combined
buffer layout, not a visible interpolation operation in P4.ASM.

con2 contains repeated four-by-four texture tiles for the ordinary sw and
v_txr1 faces, followed by manually written UV blocks for the later
non-phong faces. The last UV pairs address the plane/CPU-specific sections.
The 14 plane faces are identified by con3 plane_flag and do not use their
ordinary con2 UVs; the 12 proc faces use the final manually supplied UV
patterns. The explicit source table, rather than the texture dimensions,
is authoritative for reproducing these assignments.

### 3.3 Startup and palette construction

PART4 starts at P4.ASM:286:

1. cld is set because all subsequent string copies assume forward direction.
2. white is installed and four vertical retraces are waited.
3. archive indices 24, 25, 26, 27, 28, 29, 30, and 74 are loaded into map1,
   map2, map3, map4, logo, pic_data, pic_pal, and ruchy.
4. One selector is allocated for each texture. The screen selector/address is
   copied from the platform.
5. sort_addr is pointed at draw_tab and prepare is called.
6. n_calc is run for VWS_4/VWC_4 with 256 points and 384 faces. It creates
   per-vertex normal data for the chrome group; n_rot is the per-frame rotated
   normal output.
7. co_prepare, make_chip, make_pts, and make_pos initialize the combined
   buffers, face centres, and plane UVs.

The palette is assembled before the main loop:

~~~text
pal[64..127]  = make_pal(spal1 = sw.pal, delta -2,+4,+6, 64 entries)
pal[128..149] = make_pal(spal2 = v_txr1.pal, delta -22,-22,-22, 22 entries)
~~~

When the music state changes, the main loop installs:

~~~text
set_pal pal,   0,   256
set_pal spal1, 0,    64
set_pal spal3, 144,  33
set_pal spal4, 192,  64
~~~

Thus the final processorek Nevosolek (P4) palette is a deliberately overlaid table. The generated
sw ramp occupies 64..127, the generated v_txr1 ramp starts at 128, proc
colours overwrite the 144..176 region, and metal occupies 192..255. The
texture index is first fetched and only then offset by con3 colour. A palette
file copied into the wrong slot can therefore make an otherwise correctly
decoded texture look like a different material.

The original processorek Nevosolek (P4) source calls set_pal with spal1 at entry 0. The modern port
uses the recovered processorek Nevosolek (P4) object/capture placement for the black/unused sw entry
and the warm sw range, because the checked-in historical include and the
linked/recovered object do not expose that placement equally clearly. This
is a port compatibility detail; the source call sequence remains the
reference when auditing palette writes.

### 3.4 Plane UV generation

make_pos runs after prepare. It temporarily sets r_x to zero, builds the
object matrix, then sets r_x to 328 for later state. It transforms the 81
source vertices into pkt and subtracts 8000 from the transformed z value.
For each point it calculates:

~~~text
U = ((226+16) * p_x) / p_z + 96
V = (226    * p_y) / p_z + 60
pkt.UV = (U << 8, V << 8)
~~~

The 14 plane faces use their combined vertex indices minus the 222-vertex
base offset to address pkt. This is a projected texture coordinate
calculation performed once at startup, not a camera-relative UV calculation
performed by face.

### 3.5 Camera path and frame timing

processorek Nevosolek (P4) loads archive entry 74, whose source is CODE/P4/TRASA.DAT. Each record is
nine little-endian dwords, 36 bytes:

~~~text
offset +  0: o_x
offset +  4: o_y
offset +  8: o_z
offset + 12: r_x
offset + 16: r_y
offset + 20: r_z
offset + 24: cm_x
offset + 28: cm_y
offset + 32: cm_z
~~~

The translations are read as full dwords. The angle and camera fields are
read as signed low words by the original code. ruchow is 2951, the maximum
path index used by the clamp; the 2,964-node file has a small safety tail.
There is no interpolation between nodes. At each frame the code:

1. clamps ruchy_ptr to 0..2951;
2. loads the record at ruchy_ptr*36;
3. advances ruchy_ptr by frames*2*mnoznik;
4. reverses mnoznik at the endpoints.

frames is the tick delta returned by EOS wait_vbl. The path is therefore
frame-rate independent but intentionally skips records when a frame delta is
larger than one. Object and camera Euler values come from this path, while
the separate ro_z animation below rotates the auxiliary geometry.

### 3.6 Per-frame geometry animation

make_chip is the processorek Nevosolek (P4)-specific object animation. ro_z starts at zero, is masked
to 10 bits, and is advanced by frames*2 after the frame is drawn. It rotates
src1 into s1 and src2 followed by src3 into the contiguous s2/s3 buffers.
The effective x/y operation is:

~~~text
x' = 2 * (x*cos(ro_z) - y*sin(ro_z)) >> 15
y' = 2 * (x*sin(ro_z) + y*cos(ro_z)) >> 15
z' = z + z_offs
~~~

The source coordinates were already halved by prepare, and the doubled
result in ro_chip restores the intended scale. The same rotation is applied
to the dynamic face centres used for sorting and to the normal source
vertices. VWS_1 itself is not passed through ro_chip.

When znacznik3 is enabled, j_offs is sampled through sinus and converted to a
vertical offset:

~~~text
z_offs = (sinus[j_offs] * 1320) >> 15
~~~

j_offs advances by j_add*frames, is clamped to 0..255, and reverses j_add at
the upper bound. At the lower bound the animation flag is disabled. The
trigger is tied to the low six bits of ModPos, so the bob is a music-state
effect rather than a freely running physical simulation.

make_pts computes the integer average of the three shape vertices for every
face. The first 440 centres belong to the stationary base; the remaining
centres are rotated by make_chip. This centre data drives both depth keys and
the early bounds test.

### 3.7 processorek Nevosolek (P4) transform, projection, culling, and materials

For each face, rotate applies:

~~~text
object = ob * face_centre
camera = ca * object
world  = camera + (o_x,o_y,o_z)
~~~

The face is kept only if its centre is inside:

~~~text
-4600 <= p_x <= 4600
-4600 <= p_y <= 4600
-6600 <= p_z <= 4000
~~~

The sort key is p_z+12000. For each unique vertex the processorek Nevosolek (P4) projection is:

~~~text
denom = p_z + 7600
screen_x = ((160+32) * p_x) / denom + 160
screen_y = (160       * p_y) / denom + 100
~~~

The source uses the byte-offset con1 values and rcalc[vertex*2]. The
screen-space culling expression for visible faces is:

~~~text
(x1-x2)*(y3-y2) - (x2-x3)*(y2-y1)
~~~

processorek Nevosolek (P4) hides a face when this result is negative. Faces with con3 visibility
zero bypass this test; the 440 sw environment faces are intentionally drawn
without this cull. The 158 auxiliary faces, 12 proc faces, and 384 chrome
faces have visibility set.

show selects a material path from con3:

| Face range | Texture | Offset | UV source | Shading |
|---:|---|---:|---|---|
| 0..439 | sw | 0 | con2/pos | direct |
| first 144 of c1 | v_txr1 | 128 | con2/pos | direct |
| last 14 of c1 | sw | 64 | pkt | plane projection |
| c2, 12 faces | proc | 144 | con2/pos | direct |
| c3, 384 faces | metal | 192 | n_rot | phong/environment |

The chrome path is not a dot-product light. n_calc builds geometric normals
from VWS_4/VWC_4; rotate_normals applies the object/camera orientation; show
maps the rotated normal x/y to texture coordinates:

~~~text
U = (normal_x + 128) << 8
V = (normal_y + 108) << 8
~~~

The metal texture supplies the visible chrome/blue shading. The proc mesh is
not lit by n_rot; its appearance is entirely the proc texture plus the 144
palette offset. This is why a one-triplet proc palette shift changes the CPU
surface while leaving the rest of the scene correct.

### 3.8 Draw order, compositing, and logo

The main processorek Nevosolek (P4) loop is:

1. wait_vbl and GetModPos;
2. install the working palette when ModPos changes;
3. load and ping-pong the camera path;
4. swap the previous indexed buffer to VGA and clear the draw buffer;
5. build object/camera matrices;
6. make_chip, rotate, rotate_normals, and bit_sort;
7. show all sorted faces;
8. show_logo;
9. advance ro_z and state counters.

show_logo is a post-3D overlay. logo_a.dat contains 15 64x50 frames. The
destination begins at x=255,y=4, and texel index zero is transparent. The
frame index is sun_step*64*50. sun_step ping-pongs between frames 1 and 14;
the source changes direction through ciota and advances by an integer
frames/2 amount. Because it is written after show, it has no depth relation
to the mesh and can cover any rendered face.

### 3.9 processorek Nevosolek (P4) outro

At ModPos >= 1200h, processorek Nevosolek (P4) leaves the 3D loop. spadaj installs white, copies
tull.inc directly to the VGA framebuffer, and fades the 768-byte white
palette toward tull.pal one DAC component at a time for 64 iterations.
After the fade it holds until ModPos 1338h. The brum loop uses tablica indexed
by ModPos & 3fh; flagged entries cause two white palette writes followed by
the picture palette, creating a sub-frame flash. It exits at ModPos 1400h.

The original performs these picture and DAC writes directly. The modern port
must explicitly present after them, otherwise the correct memory contents
are never visible in a D3D window.

## 4. nad czerwonym lampa (P8): sw shell, animated metal objects, sun, and final picture

### 4.1 Composition and geometry inventory

nad czerwonym lampa (P8) declares p_len = 483 vertices and f_len = 864 faces. Its source layout is:

| Segment | Vertices/faces | Source include | Runtime role | Material |
|---|---:|---|---|---|
| Upper/base ring | 40 / 40 | SW_S_1.INC / SW_C_1.INC | stationary sw shell/ring | sw, offset 0 |
| Plane/cap section | 33 / 48 | SW_S_2.INC / SW_C_2.INC | stationary cap/transition geometry and plane UV source | sw, offsets 128/64 |
| Hero object 1 | 114 / 224 | OB_S_1.INC / OB_C_1.INC | independently rotating metal object | metal, offset 192, phong |
| Hero object 2 | 128 / 256 | OB_S_2.INC / OB_C_2.INC | independently rotating metal object | metal, offset 192, phong |
| Hero object 3 | 128 / 256 | OB_S_3.INC / OB_C_3.INC | independently rotating metal object | metal, offset 192, phong |
| Lower/closure ring | 40 / 40 | SW_S_1.INC / SW_C_1.INC again | duplicate ring shifted down in Y | sw, offset 0 |

SW_S_1 is a 20-sided two-ring shell: 40 vertices arranged as rings near
y=-814 and y=912, with 40 quad-triangulated side faces. SW_S_2 has two
16-vertex rings and a centre vertex, producing the 48 cap/transition faces.
The OB meshes are separate raw meshes but are not separate runtime scenes:
all three share the same object matrix, camera matrix, translation, painter
sort, and screen.

The final c6/s6 group is not a new external asset. It is a second assembly of
SW_S_1/SW_C_1, and prepare changes its copied y coordinates by -1620. This
deliberately supplies a lower/rear closure for the painter sequence.

### 4.2 nad czerwonym lampa (P8) assembly-time layout

nad czerwonym lampa (P8) lays out its vertex buffers as:

~~~text
src3 = OB_S_1 (114 vertices)
src4 = OB_S_2 (128 vertices)
src5 = OB_S_3 (128 vertices)

shape = SW_S_1 (40 vertices)
s2    = SW_S_2 (33 vertices)
s3    = OB_S_1 working buffer (114)
s4    = OB_S_2 working buffer (128)
s5    = OB_S_3 working buffer (128)
s6    = SW_S_1 working buffer (40)
~~~

The face buffers are con1=SW_C_1, c2=SW_C_2, c3/c4/c5=OB_C_1/2/3, and
c6=SW_C_1 again. prepare converts these to byte offsets into the combined
shape/s2/s3/s4/s5/s6 space. c6 receives the cumulative offset
40+33+114+128+128 and therefore addresses s6, not the original shape.

prepare also runs:

~~~text
for each s6 vertex:
    copy x
    copy y - 1620
    copy z
~~~

This is a real geometry change, not a palette or camera effect. c6 remains
ordinary sw material and visibility zero, so the closure ring is always
drawn without the screen-space back-face test.

co_prepare adds the cumulative vertex offsets to c3, c4, and c5 so the
normal connectivity addresses the combined normal source. It also contains
an in-place -640 y shift of s3. The following make_pts call uses that shifted
buffer to seed pts_src. make_phong then rewrites the visible s3 geometry from
src3 with shf=-640, but rotates the already-saved pts_src centres with the
same shf value. Consequently the startup ordering affects the centre data
even though the original s3 write itself is overwritten before the first
displayed frame. This redundant/asymmetric setup is an undocumented
historical quirk: preserve co_prepare, make_pts, and make_phong ordering
instead of treating the co_prepare shift as dead or applying it twice to the
working mesh.

### 4.3 Startup and nad czerwonym lampa (P8) palette

PART8 begins at P8.ASM:300:

1. bialy, a dedicated 768-byte all-63 palette, is installed.
2. The screen is cleared.
3. Archive entries 24, 27, 70, 71, 73, and 75 are loaded as sw, metal,
   last_pal, last_pic, sun, and ruchy.
4. Selectors are allocated for sw and metal.
5. make_pos computes the fixed plane UVs; prepare converts connectivity and
   builds the lower closure ring.
6. n_calc runs three times: OB_S_1/OB_C_1 (114/224), OB_S_2/OB_C_2
   (128/256), and OB_S_3/OB_C_3 (128/256). The normal sources are laid out
   consecutively in n_src/n_add.
7. co_prepare and make_pts initialize face centres and copy the hero centres
   into pts_src.

The nad czerwonym lampa (P8) palette is assembled as:

~~~text
pal[0..63]    = recovered full sw base palette
pal[64..127]  = make_pal(pal[0..63], delta -2,+4,+6)
pal[128..191] = make_pal(pal[0..63], delta +1,-1,+3)
pal[192..255] = metal.pal
~~~

The original source calls the full base include sw.pal, while the recovered
nad czerwonym lampa (P8) object shows the base as a 256-entry palette with a black entry at index
0. The port's p8_sw.pal preserves that recovered layout. nad czerwonym lampa (P8) material offsets
therefore mean:

- 0: base sw surface;
- 64: first warm/bright sw ramp;
- 128: second sw ramp;
- 192: chrome ramp.

The opening fade does not rebuild this palette. It adds ile_fade to every
component, clamps to 0..63, installs the temporary white-to-working palette,
and decrements ile_fade by frames until zero.

### 4.4 Plane UVs

make_pos temporarily sets r_x=256, builds the object matrix, then resets r_x
to zero. It transforms the 33 SW_S_2 vertices into pkt, subtracts 8000 from
z, and computes the same projected coordinates as processorek Nevosolek (P4):

~~~text
U = ((226+16) * p_x) / p_z + 96
V = (226    * p_y) / p_z + 60
pkt.UV = (U << 8, V << 8)
~~~

The 16 con3 plane faces use the SW_C_2 vertex indices minus the 40-vertex
shape offset to select pkt entries. Their material is sw with colour offset
128 and plane_flag set. The remaining 32 cap/transition faces use sw with
offset 64 and ordinary con2 UVs. This is the reason the lower cap is not
decoded by treating every nad czerwonym lampa (P8) face as a metal/phong face.

### 4.5 Camera path and timeline

nad czerwonym lampa (P8) loads entry 75, sourced from CODE/COMS/TRASA.DAT and packed as tr2.dat.
It has 2,508 nodes of the same nine-dword, 36-byte format used by processorek Nevosolek (P4):

~~~text
o_x,o_y,o_z,r_x,r_y,r_z,cm_x,cm_y,cm_z
~~~

ruchow is 2497. The camera pointer starts at zero, advances by frames*2,
and ping-pongs by changing mnoznik at the two clamp endpoints. No path
interpolation is performed. The translation fields are dwords and the
rotation/camera fields use the low signed words. The active 3D loop ends at
ModPos 2700h, after which the separate last.dat sequence begins.

The path supplies o_x/o_y/o_z and r_x/r_y/r_z/cm_x/cm_y/cm_z. nad czerwonym lampa (P8)’s three
hero rotations are not in the path: ro_1 starts at 0, ro_2 at 160, and ro_3
at -70, and they are advanced independently after every rendered frame.

### 4.6 Three independent hero rotations

make_phong applies a two-dimensional x/y rotation to each hero source and
uses the result as the current s3/s4/s5 working mesh:

~~~text
x' = (x*cos(angle) - y*sin(angle)) >> 15
y' = (x*sin(angle) + y*cos(angle)) >> 15 + (-640)
z' = z
~~~

The -640 shift is applied to the geometry output. Normals use the same x/y
rotation but shf=0, so the normal coordinate is not translated.

The three calls are:

| Working buffer | Source | Angle | Points/faces | Centre range |
|---|---|---|---:|---:|
| s3 | src3/OB_S_1 | ro_1 | 114 / 224 | first 224 hero faces |
| s4 | src4/OB_S_2 | ro_2 | 128 / 256 | next 256 hero faces |
| s5 | src5/OB_S_3 | ro_3 | 128 / 256 | final 256 hero faces |

All three calls also rotate their normal vertices into n_vert. The update
after rendering is:

~~~text
ro_1 += frames * 4
ro_2 += frames * 8
ro_3 -= frames * 8
~~~

Angles are masked to 10 bits when sampled, so they wrap naturally. These
rotations are the visible independent animation of the three metal hero
meshes; the sw shell and cap remain static in object space.

### 4.7 nad czerwonym lampa (P8) transform, projection, culling, and materials

nad czerwonym lampa (P8) uses the same Q15 object/camera matrix construction as P4. Its centre
reject bounds are:

~~~text
-3400 <= p_x <= 3400
-3400 <= p_y <= 3400
-4200 <= p_z <= 6100
~~~

The sort key is p_z+8000. Its vertex projection is intentionally different:

~~~text
denom = p_z - 7600
screen_x = ((160+32) * p_x) / denom + 160
screen_y = (-160       * p_y) / denom + 100
~~~

The negative y factor is part of the original nad czerwonym lampa (P8) orientation. Reusing processorek Nevosolek (P4)’s
positive-y projection mirrors the scene vertically and changes winding.

nad czerwonym lampa (P8) show uses the same cross-product expression as processorek Nevosolek (P4) but hides when the
result is less than or equal to zero. This differs from processorek Nevosolek (P4)’s strictly
negative rejection. The first 40 upper-ring faces and final 40 closure faces
have visibility zero and are always drawn. The 48 cap faces and all 736 hero
faces have visibility enabled.

The material groups are:

| Face range | Count | Texture | Offset | UV source |
|---:|---:|---|---:|---|
| upper sw ring | 40 | sw | 0 | con2/pos |
| first cap/plane subset | 16 | sw | 128 | pkt |
| remaining cap subset | 32 | sw | 64 | con2/pos |
| OB_S_1 | 224 | metal | 192 | n_rot |
| OB_S_2 | 256 | metal | 192 | n_rot |
| OB_S_3 | 256 | metal | 192 | n_rot |
| lower closure ring | 40 | sw | 0 | con2/pos |

The 736 hero faces all have phong_flag set. For every vertex, show subtracts
the combined normal-source offset, reads the rotated normal, and generates:

~~~text
U = (normal_x + 128) << 8
V = (normal_y + 108) << 8
~~~

As in processorek Nevosolek (P4), “phong” means environment/normal mapping into an indexed metal
texture. It is not per-pixel Phong illumination. The visible blue/silver
shading comes from metal.inc and metal.pal, while the object orientation
changes the normal-derived lookup.

### 4.8 Main loop and opening fade

The nad czerwonym lampa (P8) 3D loop is:

1. wait_vbl and GetModPos;
2. after ModPos 2630h, call brum for music-synchronised flashes;
3. clamp and load the tr2 camera record, then advance the ping-pong pointer;
4. swap the previous framebuffer and clear the draw buffer;
5. make_phong for all three hero objects;
6. build object and camera matrices;
7. rotate face centres and visible vertices;
8. rotate normals and bit-sort faces;
9. show the complete concatenated face list;
10. draw the sun sprite;
11. process keyboard control;
12. advance ro_1/ro_2/ro_3 and run fade.

fade starts with ile_fade=64. For every one of the 768 palette bytes it
computes clamp(pal[i]+ile_fade,0,63), installs white, and subtracts frames.
The framebuffer is already being drawn with the final material indices; only
the DAC values change. This explains why nad czerwonym lampa (P8) can appear as a white wash while
the indexed scene is already fully assembled.

brum begins at ModPos 2630h. It uses tablica[(ModPos & 63)*4] and a second
flag word. For a flagged beat it installs bialy twice and then the current
white palette. The double write is intentional: on VGA it creates a brief
white flash between retraces. A port that only updates memory once loses the
effect.

### 4.9 Sun sprite

sloneczko is a post-3D overlay. Entry 73 log.inc contains 19 consecutive
64x64 frames. The destination is x=254,y=-2, expressed by the original
offset (-2*320)+254; part of the sprite is therefore clipped above and to
the right of the 320x200 screen. Texel zero is transparent, all other bytes
are copied as indexed pixels.

sun_step ping-pongs between 1 and 18 and advances by frames/4, with a
minimum step of one for small frame deltas. It uses the working nad czerwonym lampa (P8) palette,
not a separate sun palette. Since it is drawn after the sorted 3D faces, it
always composites on top.

### 4.10 Keyboard control

control runs after rendering, so a key affects the next frame. The source
increments are fixed-point scene units, not pixels:

| Keys | State | Change |
|---|---|---:|
| Up/Down | o_y | -/+64 |
| Left/Right | o_x | -/+64 |
| C/X and W/Q | o_z | +64/-64 |
| F1/F2 | r_x | -/+8 |
| F3/F4 | r_y | -/+8 |
| F5/F6 | r_z | -/+8 |
| F7/F8 | cm_x | -/+8 |
| F9/F10 | cm_y | -/+8 |
| F11/F12 | cm_z | -/+8 |

This is a diagnostic/manual camera and matrix override, not part of the
recorded autonomous animation. The port maps these controls through its
Key_Map bridge.

### 4.11 nad czerwonym lampa (P8) final picture and fade

When ModPos reaches 2700h, the 3D loop stops:

1. bialy is installed, the screen is cleared, and the first 100 rows of
   last.dat are copied to rows 0..99; last.pal is installed.
2. The code holds until 2705h.
3. bialy is installed, rows 100..159 are copied, two retraces are waited,
   and last.pal is installed again.
4. It holds until 2708h.
5. bialy is installed, rows 160..198 are copied, and the final 39 rows
   complete the 320x199 source image.
6. lopa starts at ile_fade=64 and repeatedly computes
   clamp(last_pal[i]+ile_fade,0,63), decrementing through -4. This is the
   white-out of the end picture.
7. The module is stopped and the all-white state is held for 274 retraces.
8. hopla computes max(last_pal[i]-ile_fade,0), incrementing from zero
   through 64, and then returns after selector cleanup.

The one-row-short last.dat is intentional: the three slices are exactly
100+60+39 = 199 rows. Treating it as a 320x200 image reads past the asset and
changes the final fade/picture boundary.

## 5. Reconstructing each scene from scratch

### 5.1 processorek Nevosolek (P4) recipe

1. Assemble VWS_1..4 and VWC_1..4 into the exact source/buffer order shown
   above; preserve signed 16-bit coordinates.
2. Load archive entries 24..30 and 74. Keep sw, v_txr1, proc, and metal as
   indexed bytes; do not decode them as RGB images.
3. Allocate selectors or equivalent texture bases and build con1/c1/c2/c3
   byte offsets with prepare and co_prepare.
4. Run n_calc only for VWS_4/VWC_4 and retain n_vert/n_rot.
5. Generate pkt from VWS_2 using the 8.8 projection formula.
6. Build the palette overlays in the source order and install the four
   material ranges.
7. For each frame, load one 36-byte trasa node, update the ping-pong pointer,
   make_chip the three dynamic source groups, rotate face centres and unique
   vertices, rotate normals, sort, and draw.
8. Draw logo_a.dat after the mesh.
9. At 1200h switch to tull.inc and execute the palette fade/flash outro.

### 5.2 nad czerwonym lampa (P8) recipe

1. Assemble SW_S_1/SW_C_1, SW_S_2/SW_C_2, OB_S_1..3 and OB_C_1..3 into
   shape/s2/s3/s4/s5/s6 and con1/c2/c3/c4/c5/c6.
2. Load entries 24, 27, 70, 71, 73, and 75.
3. Create c6’s combined offset and subtract 1620 from s6 y coordinates.
4. Run make_pos for s2, prepare the three normal groups with n_calc, and
   make_pts. Do not treat the redundant co_prepare s3 shift as an additional
   transform.
5. Build the four nad czerwonym lampa (P8) palette regions and maintain bialy separately.
6. For each frame, load/ping-pong a tr2 node, make_phong all three hero
   objects, rotate/project/cull/sort the 864-face list, and draw material
   groups according to con3.
7. Draw log.inc after the mesh, apply input, update ro_1/2/3, fade the DAC.
8. At 2700h copy last.dat in 100/60/39-row slices, install last.pal at each
   stage, perform lopa, hold 274 retraces, and perform hopla.

## 6. Modern implementation and known differences

The modern implementation mirrors the source pipeline in
port/core/parts/p4.asm, port/core/parts/p8.asm, port/core/parts/p8_rot.asm,
port/core/parts/p8_more.asm, and the shared engine files. The significant
implementation differences are:

- The 32-bit DOS arena and selectors are represented by a 64 MB arena plus
  32-bit arena offsets. C++ receives resolved pointers through bridge.cpp.
  Arbitrary x64 FS/GS selector bases are not used.
- The original processorek Nevosolek/nad czerwonym lampa (P4/P8) face routine writes VGA memory. The port writes an
  indexed backbuffer and explicitly presents it through D3D11. Direct VGA
  picture/palette sequences therefore contain explicit present calls in the
  port.
- processorek Nevosolek (P4)’s broad-span x64 translation had a coverage defect that could leave
  disconnected triangles. Projection, culling, sorting, UV packing, and
  palette offsets remain in the NASM core, while vk_processorek_nevosolek_draw_triangle in
  bridge.cpp provides a bounded 320x200 scan conversion helper.
- nad czerwonym lampa (P8)’s original rcalc/check indexing was byte-stride sensitive. The port
  moved these high-volume scratch arrays to the arena and preserved the
  reference byte*2 index convention. The earlier *4 port stride caused the
  first-frame sort/scene corruption.
- The port has an explicit bialy buffer for P8. This prevents the initial
  pure-white state and flash path from accidentally reusing the mutable
  fade buffer.
- The port recovered missing processorek Nevosolek (P4) v_txr1.pal and proc.pal data from P4.OBJ and
  keeps the processorek Nevosolek/nad czerwonym lampa (P4/P8) sw palettes distinct. The processorek Nevosolek (P4) proc palette needed a final
  one-triplet correction; this is the vws3/vwc3 surface issue recorded in
  KNOWN_DIFFERENCES.md.
- The original sinus table and the generated port table differ by a small
  quantization choice: the original uses a 1023-interval endpoint convention,
  while the port’s generated table has a measured maximum Q15 difference of
  about 201 units. This can produce small phase/edge differences in rotation,
  bob, and sprite timing without changing scene structure.
- EOS wait_vbl is QPC-paced near 70 Hz and libxmp supplies the modern audio
  clock. The original DOS/SB16 playback is approximately five percent slower
  in wall-clock time. Scene boundaries and frame-delta animation are
  ModPos/tick aligned, but absolute pacing and audio pitch are not bit-identical.
- Current validation covers crash-free full playthroughs, archive/palette
  provenance, mesh parsing, frame recording, and the processorek Nevosolek/nad czerwonym lampa (P4/P8) palette fixes.
  It does not prove pixel equality for every phase of every moving camera
  frame; phase-aligned original-vs-port captures remain the correct test for
  final visual fidelity.

For the current status of each resolved and unresolved divergence, see
docs/KNOWN_DIFFERENCES.md. For the generic texture, palette, DATAS, and
camera-record specifications, see docs/ASSET_FORMATS.md and
docs/WORLD_ARCHITECTURE.md.

## 7. Source and port index

| Concern | Original source | Modern counterpart |
|---|---|---|
| processorek Nevosolek (P4) startup/loop/outro | CODE/P4/P4.ASM:286-540 | port/core/parts/p4.asm |
| processorek Nevosolek (P4) UVs/palette/setup | CODE/P4/P4.ASM:551-750 | port/core/parts/p4.asm |
| processorek Nevosolek (P4) animation | CODE/P4/P4.ASM:792-1045 | port/core/parts/p4.asm |
| processorek Nevosolek (P4) projection/show | CODE/P4/P4.ASM:1046-1812 | port/core/parts/p4.asm, bridge.cpp |
| processorek Nevosolek (P4) logo | CODE/P4/P4.ASM:1814-end | port/core/parts/p4.asm |
| nad czerwonym lampa (P8) startup/loop/outro | CODE/P8/P8.ASM:300-600 | port/core/parts/p8.asm |
| nad czerwonym lampa (P8) setup/palette/UVs | CODE/P8/P8.ASM:613-860 | port/core/parts/p8.asm |
| nad czerwonym lampa (P8) hero rotation | CODE/P8/P8.ASM:861-1132 | port/core/parts/p8_rot.asm |
| nad czerwonym lampa (P8) projection/show | CODE/P8/P8.ASM:1133-1900 | port/core/parts/p8.asm, p8_more.asm |
| nad czerwonym lampa (P8) input/fade/flash/sun | CODE/P8/P8.ASM:1903-end | port/core/parts/p8_more.asm |
| processorek Nevosolek (P4) geometry | CODE/DATAS/VWS_1..4.INC and VWC_1..4.INC | port/core/parts/p4_*.inc |
| nad czerwonym lampa (P8) geometry | CODE/DATAS/SW_* and OB_*.INC | port/core/parts/p8_*.inc |
| processorek Nevosolek (P4) camera | CODE/P4/TRASA.DAT, archive 74 | data/vodka.dat |
| nad czerwonym lampa (P8) camera | CODE/COMS/TRASA.DAT, archive 75 | data/vodka.dat |
| Shared raster/normal/sort primitives | CODE/INC/ENGINE.INC and linked engine objects | port/core/engine |

# Jimmy's Horde Zombies

L4D2-style horde infected for Garry's Mod: lightweight NextBot zombies, a director, spawners.

## Layout

| Folder | What it is |
|---|---|
| `addon/` | The addon itself. Put (or symlink) this folder into `garrysmod/addons/`. |
| `build/` | Animation library sources: the QCs and retargeted L4D2 animation SMDs for `inf_m` / `inf_f`. |
| `tools/` | Scripts that produce what is in `addon/` (see below). |
| `media/` | Workshop icon, preview GIFs, screenshots. |

## Tools

| Script | Does |
|---|---|
| `retarget_l4d2.py` | Retargets the L4D2 common-infected animations onto the citizen skeleton (writes `build/`). |
| `patch_citizens.py` | Copies the infected_citizens bodies and points them at the animation libraries. |
| `swap_phy_hl2.py` | Swaps the ragdoll physics for the stock HL2 citizen ones. |
| `infect_face.py` | Makes the infected face textures. |
| `build_lods.sh` | Rebuilds every body with three LOD levels and a shadow LOD (uses `lod_qc.py`, `lod_decimate.py`). |
| `build_shaders.sh` | Compiles `addon/shaders/*.hlsl` into `addon/shaders/fxc/*.vcs`. |

The Python scripts carry the absolute paths of the machine they were written on; edit the constants at the
top before running them.

`build_lods.sh` always starts from `tools/models_original/` (the bodies as they were before LODs), so it can
be re-run with other ratios: `RATIOS=0.6,0.3,0.15 tools/build_lods.sh`. If the bodies are regenerated with
`patch_citizens.py` / `swap_phy_hl2.py`, copy the new files into `tools/models_original/` and run it again,
otherwise the LODs are lost.

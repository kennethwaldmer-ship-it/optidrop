# Third-party notices

The OptiDrop scripts are MIT-licensed (see `LICENSE`). The release zip also ships the third-party
runtime files below, **unmodified**, under their own licences. Full texts are in `licenses/`.

| File(s) in `payload/` | Project | Licence | Source |
|---|---|---|---|
| `OptiScaler.dll` (FileVersion 10.0.0.1), `OptiScaler.ini`, `nvngx.dll_dlssnr.dll` | OptiScaler with DLSS Neural Rendering: [OptiScaler](https://github.com/optiscaler/OptiScaler) team, NR pass by [Dagherbou](https://github.com/Dagherbou/OptiScaler_DLSSNR) | GPL-3.0 (`licenses/OptiScaler-GPL-3.0.txt`) | Binaries are byte-identical to release [v0.2.0-dlssnr](https://github.com/Dagherbou/OptiScaler_DLSSNR/releases/tag/v0.2.0-dlssnr). The corresponding source is at that release and in [Dagherbou/OptiScaler_DLSSNR](https://github.com/Dagherbou/OptiScaler_DLSSNR). |
| NR colour composition, inside `OptiScaler.dll` | [RenoDX](https://github.com/clshortfuse/renodx) by clshortfuse | MIT (`licenses/RenoDX_ATTRIBUTION.txt`) | github.com/clshortfuse/renodx |
| `OptiScaler/amd_fidelityfx_*.dll` | AMD FidelityFX SDK | `licenses/FidelityFX_v2_LICENSE.md` | [GPUOpen FidelityFX SDK](https://github.com/GPUOpen-LibrariesAndSDKs/FidelityFX-SDK) |
| `OptiScaler/libxess*.dll`, `OptiScaler/libxell.dll` | Intel XeSS / XeLL SDK | Intel Simplified Software License (`licenses/XeSS_LICENSE.txt`) | [Intel XeSS](https://github.com/intel/xess) |

**Not included, ever:** `nvngx_dlssnr.dll`, NVIDIA's Neural Rendering model. It is NVIDIA's software
and isn't licensed for redistribution. Users supply their own copy from an NVIDIA driver package.

OptiDrop is not affiliated with NVIDIA, AMD, Intel or the OptiScaler project.

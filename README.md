## Milky Way Galaxy Simulation (C & CUDA)

Đây là dự án mô phỏng hệ đa hạt (N-body simulation) tái hiện chuyển động các thiên thể trong Milky Way bằng C và CUDA. Hiện tại codebase đã có cả đường CPU và GPU persistent, có preview realtime trên Windows, và có hai chế độ render GPU (`raytrace` và `raster`) để cân bằng chất lượng/hiệu năng.

README này mô tả trạng thái hiện tại của codebase và cách build/chạy đúng với pipeline render mới.

## Trạng thái hiện tại

- Đã có cấu trúc `SystemOfBodies` theo SoA: `mass`, `x/y/z`, `vx/vy/vz`, `ax/ay/az`, `radius`, `lum`, `absmag`, `ci`.
- **Solver CPU**: Direct O(N²) + Barnes-Hut O(N log N) octree được triển khai đầy đủ.
- **Solver GPU**: Direct O(N²) via shared-memory tiling (tối ưu CameraKernelParams precompute). Barnes-Hut/FMM đang phát triển Phase 2A–2B.
- **Integrator**: Đã hỗ trợ 2 mode trên CPU+GPU: `leapfrog` (mặc định) và `euler` (fallback để đối chiếu).
- **Memory**: Hiện tại explicit `cudaMalloc/cudaMemcpy`. Unified Memory Phase 3.
- Đã có đường GPU persistent cho simulation (`initialize_cuda_simulation` + `step_cuda_simulation`) để tránh upload lặp lại mỗi frame.
- Đã có renderer GPU với 2 mode:
	- `raytrace`: ray-sphere intersection (~912ms/frame ở 1280×720 với 119.6k stars).
	- `raster`: Gaussian splat (~2ms/frame, 450× nhanh hơn raytrace) — sản xuất path.
- Đã có telemetry render: `visible_count`, `cull_ms`, `draw/trace_ms`, `fps`.
- Đã có preview realtime Windows + CUDA-OpenGL PBO interop (zero-copy path).
- Đã hỗ trợ nạp dataset thực từ CSV (`--data data/hyg_v42.csv`). HYG v4.2: 119,626 thiên thể.
- Đã có khởi tạo ổn định dạng đĩa quay + virial relaxation tự động.

## Ổn định động lực học ban đầu

Để tránh hệ sụp nhanh về tâm (cold start), project đang áp dụng 2 lớp ổn định ngay khi tạo trạng thái ban đầu:

1. **Rotating Galactic Disk**
- Body `0` là tâm thiên hà tại `(0, 0, 0)` với khối lượng lớn.
- Các body còn lại được rải trong đĩa mỏng, vận tốc tiếp tuyến theo quỹ đạo tròn quanh tâm.

2. **Virial Relaxation**
- Sau khi có trạng thái ban đầu (từ random disk hoặc từ CSV), vận tốc được scale để đưa hệ về gần cân bằng virial:
	- `K = sum(0.5 * m * v^2)`
	- `U = sum(-G * m_i * m_j / sqrt(r^2 + softening))` với `i < j`
	- Scale vận tốc với `q = sqrt(|U| / (2K))`
- Mục tiêu là đưa hệ gần điều kiện `2K + U = 0` trước khi bắt đầu tích phân theo thời gian.

## Mục tiêu dự án

### Mục tiêu ngắn hạn

Xây dựng một phiên bản mô phỏng N-body tối thiểu chạy được với dữ liệu giả lập, có thể:

- Khởi tạo một tập hạt trong không gian 3D.
- Tính gia tốc hấp dẫn giữa các hạt.
- Cập nhật vị trí và vận tốc theo từng bước thời gian.
- Xuất kết quả ra console hoặc file để kiểm tra tính đúng.

### Mục tiêu trung hạn

- Chuyển phần tính toán chính sang CUDA để tăng tốc.
- Hỗ trợ đọc dữ liệu đầu vào từ file CSV hoặc định dạng đơn giản tương đương.
- Hoàn thiện cơ chế snapshot có metadata/index chuẩn để phục vụ trực quan hóa hoặc hậu xử lý.

### Mục tiêu dài hạn

- Tối ưu thuật toán cho số lượng hạt lớn.
- Tích hợp hiển thị 2D/3D thời gian thực.
- Nghiên cứu các thuật toán gần đúng như Barnes-Hut nếu cần mở rộng quy mô.

## Phạm vi MVP

Để tránh triển khai quá rộng ngay từ đầu, phiên bản đầu tiên nên giới hạn trong các yêu cầu sau:

- Mô phỏng N-body cơ bản theo định luật hấp dẫn Newton.
- Chạy được với vài trăm đến vài nghìn hạt.
- Chưa cần ray tracing hoặc renderer thời gian thực.
- Chưa cần dataset thiên văn thực tế ở giai đoạn đầu.
- Ưu tiên một bản CPU đúng trước khi tối ưu bằng CUDA.

Đây là lựa chọn hợp lý vì hiện codebase chưa có nền tảng mô phỏng cơ bản; nếu nhảy thẳng sang ray tracing hoặc tối ưu nâng cao thì rủi ro kỹ thuật sẽ cao và khó kiểm chứng tính đúng.

## Cấu trúc dữ liệu hiện có

Trong `main.c`, hệ vật thể được biểu diễn theo dạng Structure of Arrays (SoA):

- `mass`
- `x`, `y`, `z`
- `vx`, `vy`, `vz`
- `ax`, `ay`, `az`
- `radius`
- `lum`, `absmag`, `ci`

Cách tổ chức này phù hợp cho tối ưu hiệu năng sau này, đặc biệt khi chuyển sang CUDA vì dữ liệu đồng nhất theo từng trường sẽ dễ truy cập song song hơn.

## Kế hoạch triển khai

### Giai đoạn 1: Hoàn thiện lõi mô phỏng trên CPU

Mục tiêu:

- Tạo được chương trình C chạy độc lập.
- Kiểm chứng đúng logic vật lý trước khi tối ưu.

Việc cần làm:

- Bổ sung hàm cấp phát và giải phóng bộ nhớ cho `SystemOfBodies`.
- Viết hàm khởi tạo dữ liệu mẫu cho N vật thể.
- Viết hàm tính lực/gia tốc hấp dẫn giữa các vật thể.
- Viết hàm cập nhật vận tốc và vị trí theo bước thời gian `dt`.
- In hoặc ghi ra một số snapshot để kiểm tra kết quả.

Tiêu chí hoàn thành:

- Chạy được ít nhất 100-1000 hạt trên CPU.
- Không bị lỗi bộ nhớ.
- Giá trị vị trí/vận tốc thay đổi hợp lý qua các bước mô phỏng.

### Giai đoạn 2: Tổ chức lại mã nguồn

Mục tiêu:

- Tách mã theo module để dễ bảo trì và dễ chuyển sang CUDA.

Việc cần làm:

- Tách `main.c` thành các phần như `system`, `simulation`, `io`, `utils`.
- Định nghĩa header rõ ràng cho từng module.
- Thêm hằng số vật lý và cấu hình mô phỏng vào một nơi tập trung.

Tiêu chí hoàn thành:

- `main.c` chỉ còn vai trò điều phối chương trình.
- Các hàm mô phỏng và quản lý dữ liệu được tách biệt rõ.

### Giai đoạn 3: Tăng tốc bằng CUDA

Mục tiêu:

- Chuyển phần tính gia tốc hoặc bước cập nhật sang GPU.

Việc cần làm:

- Chuẩn hóa cấu trúc dữ liệu để copy host/device rõ ràng.
- Viết kernel CUDA cho tính toán N-body cơ bản.
- So sánh kết quả CPU và GPU trên cùng input.
- Đo thời gian thực thi để đánh giá lợi ích tăng tốc.

Tiêu chí hoàn thành:

- Kết quả GPU gần khớp CPU trong sai số chấp nhận được.
- Có benchmark đơn giản cho ít nhất 2 kích thước bài toán.

### Giai đoạn 4: Dữ liệu đầu vào và trực quan hóa

Mục tiêu:

- Mở rộng từ mô phỏng kỹ thuật sang mô phỏng có thể quan sát.

Việc cần làm:

- Hỗ trợ đọc file CSV chứa vị trí, vận tốc, khối lượng.
- Xuất snapshot ra file để vẽ bằng công cụ ngoài hoặc renderer đơn giản.
- Nếu cần, bổ sung hiển thị 2D trước khi nghĩ tới 3D hoặc ray tracing.

Tiêu chí hoàn thành:

- Có thể nạp dữ liệu đầu vào từ file.
- Có đầu ra đủ để kiểm tra quỹ đạo hoặc phân bố vật thể.

## Đề xuất cấu trúc thư mục sắp tới

```text
.
|-- build_cpu.bat
|-- build_gpu.bat
|-- main.c
|-- README.md
|-- include/
|   |-- system.h
|   |-- simulation.h
|   |-- io.h
|   |-- simulation_config.h
|   `-- cuda_nbody.h
|-- src/
|   |-- system.c
|   |-- simulation.c
|   `-- io.c
|-- cuda/
|   `-- nbody.cu
|-- data/
`-- output/
```

## Chiến lược tối ưu đa pha (1–2 tháng)

### Phạm vi và Mục tiêu
Dự án đang triển khai ba hướng chính để nâng khả năng scale và độ ổn định:

1. **Thuật toán (Algorithm)**: Triển khai song song CUDA Barnes-Hut và CUDA FMM để xử lý N > 100k hạt với throughput cao hơn O(N²) direct compute.
2. **Tích phân thời gian (Integrator)**: Nâng cấp từ Forward Euler sang Leapfrog Kick-Drift-Kick để giảm energy drift trong chạy dài hạn.
3. **Quản lý bộ nhớ (Memory)**: Chuyển từ explicit `cudaMalloc/cudaMemcpy` sang CUDA Unified Memory làm mặc định cho simulation buffers, kèm prefetch hints để tối ưu hiệu năng.

### Lộ trình triển khai

**Phase 0 (Tuần 1)**: Benchmark baseline
- Chuẩn hóa suite benchmark cho N=512, 5k, 50k, 120k
- Thu thập: steps/s, fps, cull_ms, draw_ms, force error, energy drift, momentum drift

**Phase 1 (Tuần 1–2)**: Leapfrog integrator
- Thay Forward Euler bằng Leapfrog Kick-Drift-Kick trên CPU/GPU
- Giữ fallback Euler, thêm test invariants (energy/momentum drift)

### Xác minh Phase 1 (Euler vs Leapfrog)

Chạy script so sánh drift:

```text
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\compare_integrator_drift.ps1 -NumBodies 512 -NumSteps 800 -Dt 0.01 -OutputInterval 100 -Backend gpu
```

Kết quả gần nhất (GPU, N=512, 800 steps):
- Delta Energy: Euler `0.900586%` vs Leapfrog `0.046144%`
- Center of Mass Drift: Euler `0.382517` vs Leapfrog `0.007404`
- Energy-drift reduction factor: `19.517x`

Output được ghi ra:
- `data/phase1_integrator_comparison.md`
- `data/phase1_integrator_comparison.json`

**Phase 2A (Tuần 2–4, song song 2B)**: CUDA Barnes-Hut
- Linear octree (Morton ordering + device node pool)
- Kernel: build tree, mass aggregation, force traversal (theta criterion)
- Fallback về direct CUDA khi thiếu tài nguyên

**Phase 2B (Tuần 2–5, song parallel 2A)**: CUDA FMM
- Prototype FMM 3D (P2M, M2M, M2L, L2P) với order thấp
- Cấu hình order/acceptance để trade-off accuracy–throughput
- Tùy chọn: PPPM + cuFFT nếu profiling hỗ trợ

**Phase 3 (Tuần 3–6)**: Unified Memory migration
- Chuyển g_sim_* sang `cudaMallocManaged`
- Thêm prefetch/hints, giữ explicit fallback

**Phase 4 (Tuần 5–7)**: Solver orchestration
- Mode: direct|bh|fmm
- Auto-selection policy, warmup profiling

**Phase 5 (Tuần 7–8)**: Hardening & docs
- Tiêu chí nghiệm thu, regression gates
- Benchmark matrix, cảnh báo memory budget

## Cách chạy phiên bản hiện tại

### Biên dịch trên Windows với MSVC

```text
cl /nologo /W4 /Iinclude main.c src\system.c src\simulation.c src\io.c /Fe:simulation.exe
```

Lưu ý: cần chạy trong môi trường Developer Command Prompt hoặc đã nạp `VsDevCmd.bat` để `cl.exe` có đủ include path.

Có thể dùng script có sẵn:

```text
build_cpu.bat
```

### Biên dịch bản CUDA trên Windows

```text
build_gpu.bat
```

Script này dùng `nvcc` từ CUDA 12.4 và ép host compiler về MSVC toolset `14.44`. Bản GPU hiện link thêm `opengl32.lib` cho preview/interp path.

### Biên dịch với GCC hoặc Clang

```text
gcc -Wall -Wextra -Iinclude main.c src/system.c src/simulation.c src/io.c -lm -o simulation
```

hoặc

```text
clang -Wall -Wextra -Iinclude main.c src/system.c src/simulation.c src/io.c -lm -o simulation
```

### Chạy chương trình

Chương trình hiện tại nhận tối đa 12 tham số vị trí và các cờ mở rộng:

```text
simulation[_cpu|_gpu].exe [num_bodies] [num_steps] [dt] [output_interval] [backend] [snapshot_time_interval] [render_width] [render_height] [fov] [exposure] [gamma] [camera_profile] [--render-mode <raytrace|raster>] [--integrator <leapfrog|euler>] [--solver <direct|bh|fmm>] [--theta <value>] [--clear-output] [--infinite] [--data <csv_path>]
```

Ý nghĩa:

- `num_bodies`: số lượng vật thể.
- `num_steps`: số bước mô phỏng (`inf` hoặc cờ `--infinite` để chạy vô hạn cho tới khi bấm `Esc` hoặc đóng cửa sổ preview).
- `dt`: độ dài mỗi bước thời gian.
- `output_interval`: chu kỳ in snapshot ra màn hình (số nguyên dương).
- `backend`: `cpu` hoặc `gpu`. Nếu bỏ qua thì mặc định là `cpu`.
- `snapshot_time_interval`: nếu > 0 thì ghi snapshot theo thời gian mô phỏng thực (ví dụ `0.1`), nếu bằng 0 thì dùng `output_interval` theo step như cũ.
- `render_width`, `render_height`: độ phân giải PNG render realtime khi chạy backend `gpu`. Mặc định là `1280x720`.
- `fov`: góc nhìn camera theo độ. Mặc định `60`.
- `exposure`: hệ số độ sáng cho tone mapping render. Mặc định `1.25`.
- `gamma`: hệ số gamma correction. Mặc định `2.2`.
- `camera_profile`: preset camera khởi tạo. Hỗ trợ `default`, `top`, `side`, `isometric`.
- `--render-mode <raytrace|raster>`: chọn renderer GPU. Mặc định `raytrace`.
- `--integrator <leapfrog|euler>`: chọn bộ tích phân thời gian cho CPU/GPU. Mặc định `leapfrog`, dùng `euler` khi cần đối chiếu baseline.
- `--solver <direct|bh|fmm>`: chọn solver hấp dẫn. Mặc định `direct`. CPU hỗ trợ `bh`; `fmm` đang ở mức scaffold fallback.
- `--theta <value>`: tham số mở góc cho Barnes-Hut (mặc định `0.5`).
- `--clear-output`: xóa toàn bộ file cũ trong thư mục `output/` trước khi bắt đầu run mới.
- `--infinite`: ép chạy mô phỏng vô hạn (ghi đè `num_steps`).
- `--data <csv_path>`: nạp dữ liệu thiên văn từ file CSV (ví dụ `data/hyg_v42.csv`) để mô phỏng toàn bộ dataset thay vì khởi tạo ngẫu nhiên.

Ví dụ:

```text
simulation_cpu.exe 256 200 0.01 20 cpu
simulation_gpu.exe 256 200 0.01 20 gpu
simulation_gpu.exe 512 1000 0.01 20 gpu 0.1
simulation_gpu.exe 512 1000 0.01 20 gpu 0.1 1280 720
simulation_gpu.exe 512 1000 0.01 20 gpu 0.1 1280 720 75 1.4 2.0 isometric
simulation_gpu.exe 512 inf 0.01 20 gpu 0.1 1280 720 75 1.4 2.0 isometric --clear-output
simulation_gpu.exe 512 1000 0.01 20 gpu 0.1 1280 720 75 1.4 2.0 isometric --render-mode raytrace
simulation_gpu.exe 512 1000 0.01 20 gpu 0.1 1280 720 75 1.4 2.0 isometric --render-mode raster
simulation_gpu.exe 512 1000 0.01 20 gpu 0.1 1280 720 75 1.4 2.0 isometric --render-mode raster --integrator leapfrog
simulation_gpu.exe 512 1000 0.01 20 gpu 0.1 1280 720 75 1.4 2.0 isometric --render-mode raster --integrator euler
simulation_cpu.exe 512 1000 0.01 20 cpu 0.1 1280 720 75 1.4 2.0 isometric --solver bh --theta 0.6 --integrator leapfrog
simulation_gpu.exe 512 1000 0.01 20 gpu 0.1 1280 720 75 1.4 2.0 isometric --solver direct --integrator leapfrog
simulation_gpu.exe 1 1 0.01 1 gpu 0.1 1280 720  70 1.2 2.2 default --clear-output --data data/hyg_v42.csv --infinite --render-mode raster
build_gpu.bat
simulation_gpu.exe 32 inf 0.01 2 gpu 0.02 1280 720  70 1.2 2.2 default --clear-output --data data/hyg_v42.csv --render-mode raster
```

Điều khiển realtime trong lúc chạy (Windows terminal):

- `W/S`: di chuyển camera theo trục Y.
- `A/D`: di chuyển camera theo trục X.
- `R/F`: di chuyển camera theo trục Z.
- `Arrow keys`: xoay camera (yaw/pitch).
- `Q/E`: zoom in/out.
- `[` / `]`: giảm/tăng FOV.
- `,` / `.`: giảm/tăng exposure.
- `;` / `'`: giảm/tăng gamma.
- `1/2/3/4`: chuyển nhanh camera profile `default/top/side/isometric`.
- `-` / `=`: giảm/tăng timeline timescale.
- `Space`: pause/resume mô phỏng.
- `C`: in trạng thái camera + timescale hiện tại.
- `Esc`: dừng mô phỏng sớm.

Hiện tại chương trình sẽ:

- In ra trạng thái của một vài vật thể mẫu ở các mốc bước thời gian.
- Tạo thư mục `output/` nếu chưa tồn tại.
- Ghi snapshot legacy dạng `output/step_XXXX.csv` và series dạng `output/frame_XXXXXX.csv` kèm `output/series_meta.json`, `output/snapshots_index.csv` để phục vụ pipeline trực quan hóa/hậu xử lý.
- Khi chạy GPU, render PNG sequence dạng `output/render_XXXXXX.png` theo mode hiện tại (`raytrace` hoặc `raster`).
- Khi chạy GPU, mở cửa sổ preview realtime trên Windows; nếu khả dụng sẽ bật CUDA-OpenGL PBO interop để giảm copy host-side cho đường hiển thị.
- Đường GPU dùng persistent simulation buffers dùng chung cho compute/render để giảm upload lặp lại và tăng FPS.
- Preview/HUD hiển thị realtime: `step`, `time`, `FPS`, `mode`, `exposure`, `gamma`, `FOV`, `zoom`, `time_scale`.
- Console telemetry in theo frame: `[Render] step=... mode=... visible=... cull=...ms draw=...ms fps=...`.
- Nếu dùng dữ liệu random (không `--data`), hệ được khởi tạo dạng đĩa quay + virial relaxation trước khi chạy.
- Nếu dùng `--data`, dữ liệu vận tốc từ catalog cũng được virial relaxation tự động để giảm mất cân bằng động năng/thế năng ban đầu.

## Yêu cầu môi trường dự kiến

- Windows + MSVC toolchain (script hiện tại đã cấu hình cho môi trường này).
- CUDA Toolkit 12.x (đang dùng 12.4).
- GPU NVIDIA hỗ trợ CUDA.
- OpenGL runtime (Windows `opengl32.dll`) cho preview interop path.

## Ghi chú

Project đã vượt phạm vi baseline ban đầu: dataset real, preview realtime, raytrace/raster renderer, benchmark/test GPU, PBO interop, galaxy disk + virial relaxation.

**Trạng thái hiện tại (Mar 2026)**:
- GPU direct solver: tối ưu shared-memory tiling, pass 74 GPU tests.
- Raster path sản xuất (~2ms/frame, 120k stars); raytrace dùng QA (non-scaling).
- Leapfrog (mặc định): giảm energy drift dài hạn; Euler vẫn giữ làm fallback đối chiếu.
- Explicit memory: hiệu quả hiện tại, sẵn sàng UM migration.

**Phase tiếp theo (tuần 1–8)**:
Solver scale-up (BH+FMM, Phase 2A–2B), integrator symplectic (Phase 1), memory architecture (Phase 3). Xem "Chiến lược tối ưu đa pha" để chi tiết roadmap, mốc, tiêu chí.
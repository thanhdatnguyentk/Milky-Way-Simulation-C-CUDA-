## Milky Way Galaxy Simulation (C & CUDA)

Đây là dự án mô phỏng hệ đa hạt (N-body simulation) hướng tới bài toán tái hiện chuyển động của các thiên thể trong thiên hà Milky Way bằng C và CUDA. Mục tiêu dài hạn là vừa đảm bảo mô phỏng đúng về mặt vật lý, vừa tận dụng GPU để tăng hiệu năng.

Ở thời điểm hiện tại, dự án đã có bản baseline N-body trên CPU và đã được tách thành các module `system`, `simulation`, `io`. README này mô tả trạng thái hiện tại của codebase, phạm vi MVP, và lộ trình triển khai tiếp theo.

## Trạng thái hiện tại

- Đã có cấu trúc `SystemOfBodies` để lưu thông tin khối lượng, vị trí, vận tốc và gia tốc của các hạt.
- Đã có bản baseline trên CPU gồm: cấp phát bộ nhớ, khởi tạo dữ liệu ngẫu nhiên, tính gia tốc hấp dẫn, cập nhật trạng thái theo bước thời gian và in snapshot kiểm tra.
- Đã có xuất snapshot dạng series trong thư mục `output/` gồm: `series_meta.json`, `snapshots_index.csv`, và các frame `frame_XXXXXX.csv` phục vụ trực quan hóa/hậu xử lý.
- Mã nguồn đã được tách module thành `main.c`, `src/system.c`, `src/simulation.c`, `src/io.c` và các header tương ứng trong `include/`.
- Đã có đường chạy CUDA tùy chọn cho bước tính gia tốc, có thể bật bằng backend `gpu` nếu build đúng toolchain.
- Chưa có nạp dataset thực tế.

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

Trong [main.c](main.c), hệ vật thể đang được biểu diễn theo dạng Structure of Arrays (SoA):

- `mass`
- `x`, `y`, `z`
- `vx`, `vy`, `vz`
- `ax`, `ay`, `az`

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

## Công việc ưu tiên tiếp theo

1. Chuẩn hóa dữ liệu đầu vào thay cho khởi tạo ngẫu nhiên hoàn toàn.
2. Thêm so sánh kết quả CPU và GPU trên cùng input để kiểm chứng sai số.
3. Bổ sung kiểm tra năng lượng hoặc động lượng để đánh giá độ ổn định số.
4. Tối ưu đường chạy CUDA để giảm chi phí cấp phát và copy bộ nhớ mỗi bước.

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

Script này hiện dùng `nvcc` từ CUDA 12.4 và ép host compiler về MSVC toolset `14.44` để tránh lỗi tương thích với toolchain Insiders mới hơn.

### Biên dịch với GCC hoặc Clang

```text
gcc -Wall -Wextra -Iinclude main.c src/system.c src/simulation.c src/io.c -lm -o simulation
```

hoặc

```text
clang -Wall -Wextra -Iinclude main.c src/system.c src/simulation.c src/io.c -lm -o simulation
```

### Chạy chương trình

Chương trình hiện tại nhận tối đa 12 tham số dòng lệnh và 2 cờ tùy chọn:

```text
simulation [num_bodies] [num_steps] [dt] [output_interval] [backend] [snapshot_time_interval] [render_width] [render_height] [fov] [exposure] [gamma] [camera_profile] [--clear-output] [--infinite] [--data <csv_path>]
```

Ý nghĩa:

- `num_bodies`: số lượng vật thể.
- `num_steps`: số bước mô phỏng (`inf` hoặc cờ `--infinite` để chạy vô hạn cho tới khi bấm `Esc` hoặc đóng cửa sổ preview).
- `dt`: độ dài mỗi bước thời gian.
- `output_interval`: chu kỳ in snapshot ra màn hình.
- `backend`: `cpu` hoặc `gpu`. Nếu bỏ qua thì mặc định là `cpu`.
- `snapshot_time_interval`: nếu > 0 thì ghi snapshot theo thời gian mô phỏng thực (ví dụ `0.1`), nếu bằng 0 thì dùng `output_interval` theo step như cũ.
- `render_width`, `render_height`: độ phân giải PNG render realtime khi chạy backend `gpu`. Mặc định là `1280x720`.
- `fov`: góc nhìn camera theo độ. Mặc định `60`.
- `exposure`: hệ số độ sáng cho tone mapping render. Mặc định `1.25`.
- `gamma`: hệ số gamma correction. Mặc định `2.2`.
- `camera_profile`: preset camera khởi tạo. Hỗ trợ `default`, `top`, `side`, `isometric`.
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
simulation_gpu.exe 1 1 0.01 1 gpu 0.1 640 360 70 1.2 2.2 default --clear-output --data data/hyg_v42.csv --infinite
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
- Khi chạy GPU, render thêm PNG sequence dạng `output/render_XXXXXX.png` bằng CUDA raster kernel, dùng camera realtime hiện tại và ánh xạ màu theo `ci`, độ sáng theo `lum`.
- Khi chạy GPU, mở thêm cửa sổ preview realtime trên Windows để camera thay đổi là thấy ngay frame trên màn hình.
- Đường GPU hiện dùng persistent simulation buffers dùng chung cho compute và render, giúp giảm upload lặp lại và tăng FPS so với đường tách rời trước đó.
- Preview window có HUD overlay realtime gồm: `step`, `time`, `FPS`, `exposure`, `gamma`, `FOV`, `zoom`, `time_scale`.

## Yêu cầu môi trường dự kiến

- Trình biên dịch C: GCC hoặc Clang.
- CUDA Toolkit: dùng khi bắt đầu giai đoạn GPU.
- Hệ điều hành: Linux hoặc Windows đều khả thi, miễn có toolchain phù hợp.

## Ghi chú

README cũ mô tả nhiều tính năng nâng cao như ray tracing và dựng hình 720p theo thời gian thực. Những mục đó vẫn có thể là định hướng dài hạn, nhưng chưa nên coi là phạm vi triển khai ngay lúc này. Thứ tự hợp lý là: đúng vật lý trước, mô-đun hóa sau, tăng tốc GPU tiếp theo, rồi mới đến trực quan hóa.
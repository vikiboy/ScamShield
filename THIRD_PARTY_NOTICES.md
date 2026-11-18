# Third-party notices

ScamShield's own code is MIT-licensed (see [LICENSE](LICENSE)). It does **not** vendor or redistribute
the components below: the installer downloads them from their official sources, under their own licenses.
They are listed here with their notices for attribution.

| Component | Used for | Author | License | Source |
|---|---|---|---|---|
| Kev (`kev` Python package and server) | Decision model server, `/v1/systemone` | Jared Palmer | Apache-2.0 | https://github.com/jaredpalmer/kev |
| `jaredpalmer/kev-4b` | Decision model (LoRA adapter) | Jared Palmer | Apache-2.0 | https://huggingface.co/jaredpalmer/kev-4b |
| `Qwen/Qwen3.5-4B-Base` | Kev-4B base model | Qwen team, Alibaba Cloud | Apache-2.0 | https://huggingface.co/Qwen/Qwen3.5-4B-Base |
| `mlx-community/Qwen3.5-4B-MLX-4bit` | Summary writer model | Qwen team; MLX conversion by mlx-community | Apache-2.0 | https://huggingface.co/mlx-community/Qwen3.5-4B-MLX-4bit |
| MLX | On-device ML framework | Apple Inc. | MIT | https://github.com/ml-explore/mlx |
| mlx-lm | Model serving (`mlx_lm.server`) | Apple Inc. | MIT | https://github.com/ml-explore/mlx-lm |
| Stageshow (React kit) | README animation (`design/readme-hero/`) | Benji Taylor | MIT | Stageshow skill |
| XcodeGen | Generates the iOS Xcode project | Yonas Kolb and contributors | MIT | https://github.com/yonaskolb/XcodeGen |
| uv | Python environment for the model services | Astral | MIT or Apache-2.0 | https://github.com/astral-sh/uv |

**Data and services** (terms of the provider apply; no data is redistributed in this repository):

- FCC Consumer Complaints open data (dataset `3xyp-aqkj`): https://opendata.fcc.gov
- FTC Do Not Call reported calls API (needs your own api.data.gov key): https://www.ftc.gov/developer
- RoboKiller public lookup pages (lookup.robokiller.com). ScamShield is not affiliated with or endorsed by RoboKiller; each lookup sends only the number being checked.
- The decider speaks the TypeSafe System One request format: https://docs.typesafe.ai

Apple, iPhone, iCloud, FaceTime and Xcode are trademarks of Apple Inc. ScamShield is not affiliated with Apple.

---

## Kev: Apache License 2.0

```
Kev is licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
```

The Qwen3.5 models are also distributed under the Apache License 2.0 (same text; copyright Alibaba Cloud).

## MLX

```
MIT License

Copyright © 2023 Apple Inc.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## mlx-lm

```
MIT License

Copyright © 2023 Apple Inc.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Stageshow

```
MIT License

Copyright (c) 2026 Benji Taylor

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

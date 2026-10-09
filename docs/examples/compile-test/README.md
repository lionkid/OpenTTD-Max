# compile-test

企劃書（docs/PLAN.md）第 8 節所有語法的最小可編譯範例，已用 nmlc 0.9.0 驗證：
協和號（2179 km/h）、737 variant group、N700 articulated + tilt、L0 磁浮（603 km/h）、badges、
railtype fallback、32bpp 1x/2x/4x + 公司色 mask、英文與繁中語言檔。

```bash
pip install nml==0.9.0
python3 make_placeholder_sprites.py          # writes gfx/*.png (not committed)
nmlc -c --grf compile-test.grf compile-test.nml
```

圖檔為純色方塊佔位，只用來驗證檔案格式與調色盤。

AutoLoot — Media
================

Save your custom background image here as:

    Background.tga   (Targa, easiest to produce)
    -- or --
    Background.blp   (Blizzard native; needs BLPConverter, faster to load)

If you use BLP instead of TGA, change the file extension referenced in
AutoLoot.lua under EAL_BuildGUI:

    bgImage:SetTexture("Interface\\AddOns\\AutoLoot\\Media\\Background.tga")

Recommendations
---------------
- Power-of-2 dimensions for best performance: 1024x512, 1024x1024, etc.
- The settings window is 720x520 in v4.10.0; image is stretched to fit.
- If the file is missing, the addon falls back to a solid violet backdrop
  (no errors -- the texture simply doesn't render).

Converting PNG/JPG -> TGA
-------------------------
- GIMP:        File -> Export As -> Background.tga
- Paint.NET:   Save As -> Targa (.tga)
- Photoshop:   Save As -> Targa, 32-bit

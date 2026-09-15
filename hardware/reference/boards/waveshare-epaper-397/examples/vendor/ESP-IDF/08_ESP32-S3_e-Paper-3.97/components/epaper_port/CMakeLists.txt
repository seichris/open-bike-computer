idf_component_register(
  SRCS "epaper_bsp.c" "epaper_port.c" "ImageData.c"
  PRIV_REQUIRES driver fatfs sdmmc sdcard_bsp axpPower epaper_lib
  INCLUDE_DIRS "./")

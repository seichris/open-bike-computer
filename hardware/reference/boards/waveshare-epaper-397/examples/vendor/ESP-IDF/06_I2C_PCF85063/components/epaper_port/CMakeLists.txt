idf_component_register(
  SRCS "epaper_bsp.c" "epaper_port.c" "ImageData.c"
  PRIV_REQUIRES driver epaper_lib
  INCLUDE_DIRS "./")

#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>

namespace line_rasterizer {

namespace detail {

struct PointF {
  float x;
  float y;
};

inline void plot(uint16_t *buf, int32_t width, int32_t height,
                 uint32_t stride, int32_t x, int32_t y, uint16_t color) {
  if (x >= 0 && x < width && y >= 0 && y < height)
    buf[y * stride + x] = color;
}

inline void fillSpan(uint16_t *buf, int32_t width, int32_t height,
                     uint32_t stride, int32_t y, int32_t x1, int32_t x2,
                     uint16_t color) {
  if (y < 0 || y >= height || x2 < 0 || x1 >= width)
    return;

  x1 = std::max<int32_t>(x1, 0);
  x2 = std::min<int32_t>(x2, width - 1);
  uint16_t *row = buf + y * stride;
  for (int32_t x = x1; x <= x2; ++x)
    row[x] = color;
}

inline void drawThinLine(uint16_t *buf, int32_t width, int32_t height,
                         uint32_t stride, int32_t x1, int32_t y1, int32_t x2,
                         int32_t y2, uint16_t color) {
  int32_t dx = std::abs(x2 - x1);
  int32_t sx = x1 < x2 ? 1 : -1;
  int32_t dy = -std::abs(y2 - y1);
  int32_t sy = y1 < y2 ? 1 : -1;
  int32_t error = dx + dy;

  while (true) {
    plot(buf, width, height, stride, x1, y1, color);
    if (x1 == x2 && y1 == y2)
      break;

    const int32_t twiceError = 2 * error;
    if (twiceError >= dy) {
      error += dy;
      x1 += sx;
    }
    if (twiceError <= dx) {
      error += dx;
      y1 += sy;
    }
  }
}

inline uint8_t clipOutCode(float x, float y, float minX, float minY,
                           float maxX, float maxY) {
  uint8_t code = 0;
  if (x < minX)
    code |= 1;
  else if (x > maxX)
    code |= 2;
  if (y < minY)
    code |= 4;
  else if (y > maxY)
    code |= 8;
  return code;
}

inline bool clipLine(float &x1, float &y1, float &x2, float &y2, float minX,
                     float minY, float maxX, float maxY) {
  uint8_t code1 = clipOutCode(x1, y1, minX, minY, maxX, maxY);
  uint8_t code2 = clipOutCode(x2, y2, minX, minY, maxX, maxY);

  while (true) {
    if ((code1 | code2) == 0)
      return true;
    if ((code1 & code2) != 0)
      return false;

    const uint8_t outsideCode = code1 != 0 ? code1 : code2;
    float x = 0.0f;
    float y = 0.0f;

    if (outsideCode & 8) {
      if (y2 == y1)
        return false;
      x = x1 + (x2 - x1) * (maxY - y1) / (y2 - y1);
      y = maxY;
    } else if (outsideCode & 4) {
      if (y2 == y1)
        return false;
      x = x1 + (x2 - x1) * (minY - y1) / (y2 - y1);
      y = minY;
    } else if (outsideCode & 2) {
      if (x2 == x1)
        return false;
      y = y1 + (y2 - y1) * (maxX - x1) / (x2 - x1);
      x = maxX;
    } else {
      if (x2 == x1)
        return false;
      y = y1 + (y2 - y1) * (minX - x1) / (x2 - x1);
      x = minX;
    }

    if (outsideCode == code1) {
      x1 = x;
      y1 = y;
      code1 = clipOutCode(x1, y1, minX, minY, maxX, maxY);
    } else {
      x2 = x;
      y2 = y;
      code2 = clipOutCode(x2, y2, minX, minY, maxX, maxY);
    }
  }
}

inline void fillConvexQuad(uint16_t *buf, int32_t width, int32_t height,
                           uint32_t stride, const PointF (&points)[4],
                           uint16_t color) {
  float minY = points[0].y;
  float maxY = points[0].y;
  for (uint8_t i = 1; i < 4; ++i) {
    minY = std::min(minY, points[i].y);
    maxY = std::max(maxY, points[i].y);
  }

  const int32_t firstY =
      std::max<int32_t>(0, static_cast<int32_t>(std::ceil(minY)));
  const int32_t lastY =
      std::min<int32_t>(height - 1, static_cast<int32_t>(std::floor(maxY)));

  for (int32_t y = firstY; y <= lastY; ++y) {
    float minX = 0.0f;
    float maxX = 0.0f;
    bool foundIntersection = false;

    for (uint8_t i = 0; i < 4; ++i) {
      const PointF &a = points[i];
      const PointF &b = points[(i + 1) % 4];
      const float edgeMinY = std::min(a.y, b.y);
      const float edgeMaxY = std::max(a.y, b.y);
      if (y < edgeMinY || y > edgeMaxY)
        continue;

      if (a.y == b.y) {
        if (std::fabs(static_cast<float>(y) - a.y) > 0.0001f)
          continue;
        const float edgeMinX = std::min(a.x, b.x);
        const float edgeMaxX = std::max(a.x, b.x);
        if (!foundIntersection) {
          minX = edgeMinX;
          maxX = edgeMaxX;
          foundIntersection = true;
        } else {
          minX = std::min(minX, edgeMinX);
          maxX = std::max(maxX, edgeMaxX);
        }
        continue;
      }

      const float t = (static_cast<float>(y) - a.y) / (b.y - a.y);
      const float x = a.x + t * (b.x - a.x);
      if (!foundIntersection) {
        minX = x;
        maxX = x;
        foundIntersection = true;
      } else {
        minX = std::min(minX, x);
        maxX = std::max(maxX, x);
      }
    }

    if (foundIntersection) {
      fillSpan(buf, width, height, stride, y,
               static_cast<int32_t>(std::ceil(minX)),
               static_cast<int32_t>(std::floor(maxX)), color);
    }
  }
}

inline void fillDisc(uint16_t *buf, int32_t width, int32_t height,
                     uint32_t stride, float centerX, float centerY,
                     float radius, uint16_t color) {
  const int32_t firstY =
      std::max<int32_t>(0, static_cast<int32_t>(std::ceil(centerY - radius)));
  const int32_t lastY = std::min<int32_t>(
      height - 1, static_cast<int32_t>(std::floor(centerY + radius)));
  const float radiusSquared = radius * radius;

  for (int32_t y = firstY; y <= lastY; ++y) {
    const float dy = static_cast<float>(y) - centerY;
    const float remaining = radiusSquared - dy * dy;
    if (remaining < 0.0f)
      continue;

    const float xRadius = std::sqrt(remaining);
    fillSpan(buf, width, height, stride, y,
             static_cast<int32_t>(std::ceil(centerX - xRadius)),
             static_cast<int32_t>(std::floor(centerX + xRadius)), color);
  }
}

} // namespace detail

/**
 * Draws an opaque, filled line directly into an RGB565 pixel buffer.
 *
 * Thick lines are rasterized as a filled rectangle with round end caps. This
 * avoids the unwritten pixels produced by approximating thickness with several
 * rounded, parallel one-pixel Bresenham lines.
 */
inline void drawFilledLine(uint16_t *buf, int32_t width, int32_t height,
                           uint32_t stride, int16_t x1, int16_t y1, int16_t x2,
                           int16_t y2, uint16_t color, uint8_t lineWidth) {
  if (buf == nullptr || width <= 0 || height <= 0 ||
      stride < static_cast<uint32_t>(width))
    return;

  lineWidth = std::max<uint8_t>(lineWidth, 1);
  if (y2 < y1 || (y2 == y1 && x2 < x1)) {
    std::swap(x1, x2);
    std::swap(y1, y2);
  }

  const float clipMargin = static_cast<float>(lineWidth) + 2.0f;
  float startX = x1;
  float startY = y1;
  float endX = x2;
  float endY = y2;
  if (!detail::clipLine(startX, startY, endX, endY, -clipMargin, -clipMargin,
                        static_cast<float>(width - 1) + clipMargin,
                        static_cast<float>(height - 1) + clipMargin)) {
    return;
  }

  if (lineWidth == 1) {
    detail::drawThinLine(
        buf, width, height, stride,
        static_cast<int32_t>(std::round(startX)),
        static_cast<int32_t>(std::round(startY)),
        static_cast<int32_t>(std::round(endX)),
        static_cast<int32_t>(std::round(endY)), color);
    return;
  }

  const float dx = endX - startX;
  const float dy = endY - startY;
  const float length = std::sqrt(dx * dx + dy * dy);
  if (length < 0.0001f) {
    const bool evenWidth = (lineWidth % 2) == 0;
    const float centerOffset = evenWidth ? 0.5f : 0.0f;
    const float radius = evenWidth
                             ? static_cast<float>(lineWidth) * 0.5f
                             : (static_cast<float>(lineWidth) - 1.0f) * 0.5f;
    detail::fillDisc(buf, width, height, stride, startX + centerOffset,
                     startY + centerOffset, radius, color);
    return;
  }

  float normalX = -dy / length;
  float normalY = dx / length;
  if (normalY < 0.0f || (normalY == 0.0f && normalX < 0.0f)) {
    normalX = -normalX;
    normalY = -normalY;
  }

  const int16_t lowerOffset =
      -static_cast<int16_t>((lineWidth - 1) / 2);
  const int16_t upperOffset = static_cast<int16_t>(lineWidth / 2);
  const float centerOffset =
      (static_cast<float>(lowerOffset) + upperOffset) * 0.5f;
  const float radius =
      (static_cast<float>(upperOffset) - lowerOffset) * 0.5f;

  const detail::PointF quad[4] = {
      {startX + normalX * lowerOffset, startY + normalY * lowerOffset},
      {startX + normalX * upperOffset, startY + normalY * upperOffset},
      {endX + normalX * upperOffset, endY + normalY * upperOffset},
      {endX + normalX * lowerOffset, endY + normalY * lowerOffset},
  };
  detail::fillConvexQuad(buf, width, height, stride, quad, color);

  const float shiftedStartX = startX + normalX * centerOffset;
  const float shiftedStartY = startY + normalY * centerOffset;
  const float shiftedEndX = endX + normalX * centerOffset;
  const float shiftedEndY = endY + normalY * centerOffset;
  detail::fillDisc(buf, width, height, stride, shiftedStartX, shiftedStartY,
                   radius, color);
  detail::fillDisc(buf, width, height, stride, shiftedEndX, shiftedEndY, radius,
                   color);
}

} // namespace line_rasterizer

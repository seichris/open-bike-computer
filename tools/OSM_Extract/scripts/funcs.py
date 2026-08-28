from shapely import (
    GeometryCollection,
    LineString,
    LinearRing,
    MultiLineString,
    MultiPolygon,
    Point,
    Polygon,
    geometry,
    intersection,
)
from shapely.ops import triangulate, unary_union
import PIL.ImageDraw as ImageDraw
import PIL.Image as Image
import math

from label_pipeline import extract_join_metadata, extract_label_tags

IMG_WIDTH, IMG_HEIGHT = pow( 2, 12), pow( 2, 12) # 4096 x 4096
BACKGROUND_COLOR = 0xDDDDDD
MAX_GENERIC_POLYGON_PIECES_PER_SOURCE = 2048
MAX_GENERIC_POLYGON_PIECES_PER_BLOCK = 32768
_GEOMETRY_EQUIVALENCE_RELATIVE_TOLERANCE = 1e-9
_GEOMETRY_EQUIVALENCE_ABSOLUTE_TOLERANCE = 1e-7


class GenericGeometryError(ValueError):
    code = "generic_geometry_invalid"


class GenericGeometryLimitError(GenericGeometryError):
    code = "generic_geometry_amplification_limit"

PI = 3.14159265358979323846264338327950288
def DEG2RAD(a): return ((a) / (180 / PI))
def RAD2DEG(a): return ((a) * (180 / PI))
EARTH_RADIUS = 6378137
def lat2y( lat): return round( math.log( math.tan( DEG2RAD(lat) / 2 + PI/4 )) * EARTH_RADIUS)
def lon2x( lon): return round( DEG2RAD(lon) * EARTH_RADIUS)


def parse_tags(tags_str):
    """ Extract the tags as dict
    """
    res = dict()
    if not isinstance(tags_str, str) or not tags_str:
        return res

    tags = tags_str.split('","')
    for tag in tags:
        tag = tag.replace('"','')
        parts = tag.split('=>', 1)
        if len(parts) != 2 or not parts[0]:
            continue
        res[parts[0]] = parts[1]
    return res


def _record_geometry_drop(diagnostics, code):
    if diagnostics is None:
        return
    diagnostics["droppedGeometryCount"] = diagnostics.get("droppedGeometryCount", 0) + 1
    dropped_by_code = diagnostics.setdefault("droppedByCode", {})
    dropped_by_code[code] = dropped_by_code.get(code, 0) + 1


def _ring_area(coordinates):
    return sum(
        (coordinates[index][0] * coordinates[index + 1][1])
        - (coordinates[index + 1][0] * coordinates[index][1])
        for index in range(len(coordinates) - 1)
    ) / 2.0


def _canonical_ring(raw_coordinates, *, clockwise):
    if not isinstance(raw_coordinates, (list, tuple)):
        raise GenericGeometryError("polygon ring is not an array")

    coordinates = []
    for raw_coordinate in raw_coordinates:
        if not isinstance(raw_coordinate, (list, tuple)) or len(raw_coordinate) < 2:
            raise GenericGeometryError("polygon coordinate is not an x/y pair")
        x, y = raw_coordinate[0], raw_coordinate[1]
        if (
            isinstance(x, bool)
            or isinstance(y, bool)
            or not isinstance(x, (int, float))
            or not isinstance(y, (int, float))
            or not math.isfinite(x)
            or not math.isfinite(y)
        ):
            raise GenericGeometryError("polygon coordinate is not finite")
        coordinate = (float(x), float(y))
        if not coordinates or coordinate != coordinates[-1]:
            coordinates.append(coordinate)

    if coordinates and coordinates[0] == coordinates[-1]:
        coordinates.pop()
    if len(coordinates) < 3 or len(set(coordinates)) < 3:
        raise GenericGeometryError("polygon ring has fewer than three distinct coordinates")

    coordinates.append(coordinates[0])
    area = _ring_area(coordinates)
    if not math.isfinite(area) or area == 0:
        raise GenericGeometryError("polygon ring has zero or non-finite area")
    if (area < 0) != clockwise:
        open_coordinates = list(reversed(coordinates[:-1]))
    else:
        open_coordinates = coordinates[:-1]

    start = min(range(len(open_coordinates)), key=open_coordinates.__getitem__)
    canonical = open_coordinates[start:] + open_coordinates[:start]
    canonical.append(canonical[0])
    return canonical


def _canonical_polygon(raw_component):
    if not isinstance(raw_component, (list, tuple)) or not raw_component:
        raise GenericGeometryError("polygon has no exterior ring")
    exterior = _canonical_ring(raw_component[0], clockwise=False)
    interiors = [
        _canonical_ring(raw_ring, clockwise=True)
        for raw_ring in raw_component[1:]
    ]
    interiors.sort(key=lambda ring: tuple(ring))
    polygon = Polygon(exterior, interiors)
    if polygon.is_empty or not polygon.is_valid or polygon.area <= 0:
        raise GenericGeometryError("polygon rings do not form a valid area")
    return polygon


def _polygon_sort_key(polygon):
    return (
        tuple(polygon.bounds),
        polygon.area,
        tuple(polygon.exterior.coords),
        tuple(tuple(interior.coords) for interior in polygon.interiors),
    )


def _canonicalize_shapely_polygon(polygon):
    return _canonical_polygon(
        [
            list(polygon.exterior.coords),
            *[list(interior.coords) for interior in polygon.interiors],
        ]
    )


def get_geoms(osm_geom, geometry_diagnostics=None):
    """ Converts the geometry or multigeometry to a list of simple geometries (LineString, Polygon)
    """
    geoms = []
    if not isinstance(osm_geom, dict):
        _record_geometry_drop(geometry_diagnostics, "geometry_not_object")
        return geoms
    geom_type = osm_geom.get('type')
    if geom_type == 'LineString':
        geoms.append( LineString( osm_geom['coordinates']))
    elif geom_type == 'Polygon':
        components = [osm_geom.get('coordinates')]
        for component in components:
            try:
                geoms.append(_canonical_polygon(component))
            except (GenericGeometryError, TypeError, ValueError):
                _record_geometry_drop(geometry_diagnostics, "invalid_polygon_component")
    elif geom_type == 'MultiLineString':
        for g in osm_geom['coordinates']:
            geoms.append( LineString( g))
    elif geom_type == 'MultiPolygon':
        components = osm_geom.get('coordinates')
        if not isinstance(components, (list, tuple)):
            _record_geometry_drop(geometry_diagnostics, "invalid_multipolygon")
            return geoms
        for component in components:
            try:
                geoms.append(_canonical_polygon(component))
            except (GenericGeometryError, TypeError, ValueError):
                _record_geometry_drop(geometry_diagnostics, "invalid_polygon_component")
        geoms.sort(key=_polygon_sort_key)
    else:
        _record_geometry_drop(geometry_diagnostics, "unsupported_geometry_type")
    # elif geom_type == 'GeometryCollection': # TODO
    #     return []    
    # else: print("ERROR: unknow geometry type:", geom_type)
    return geoms

def process_features(
    features,
    conf,
    label_diagnostics=None,
    geometry_diagnostics=None,
):
    """ Extract the features based in the definitions in conf: which features to extract and which tags
    """
    extracted = []
    total = len(features)
    done = 0
    for feature_index, feature in enumerate(features):
        properties = feature['properties']
        if 'other_tags' in feature['properties']:
            tags = parse_tags( feature['properties']['other_tags'] )
        else: tags = dict()

        label_tags = extract_label_tags(properties, tags, diagnostics=label_diagnostics)
        label_join = extract_join_metadata(properties, tags)
        building_tags = {
            key: tags[key]
            for key in (
                'building', 'building:part', 'height', 'min_height',
                'building:levels', 'building:min_level', 'roof:height',
                'roof:levels',
            )
            if key in tags
        }
        
        # some features are defined just by a tag in "other_Tags", like railway
        # we add them to the properties
        if 'tags' in conf: 
            for tag in conf['tags']:
                if tag in tags: 
                    properties[tag] = tags[tag]

        feature_type = None
        feature_type_tags = []
        z_order = properties['z_order'] if 'z_order' in properties else None
        for conf_feat_type in conf['feature_types']:
            if conf_feat_type in properties:
                feat_subtype = properties[ conf_feat_type ]
                filter_by_subtype = (len( conf['feature_types'][conf_feat_type]) > 0) 
                if filter_by_subtype and not feat_subtype in conf['feature_types'][conf_feat_type]: continue
                feature_type = conf_feat_type + '.' + feat_subtype
                if isinstance( conf['feature_types'][conf_feat_type], list): break # no tags to check, we are done
                conf_feature_tags = conf['feature_types'][conf_feat_type][feat_subtype]
                for feat_subtype_tag in conf_feature_tags:
                    if feat_subtype_tag in tags:
                        feature_type_tags.append( feat_subtype_tag + '.' + tags[feat_subtype_tag])
                break

        if not feature_type: 
            done += 1
            continue
        # geom can be one or several lines or polygons
        geoms = get_geoms(
            feature['geometry'], geometry_diagnostics=geometry_diagnostics
        )
        id = properties['osm_way_id'] if 'osm_way_id' in properties else \
            properties['osm_id'] if 'osm_id' in properties else ''
        osm_key = (
            'w' + str(properties['osm_way_id'])
            if properties.get('osm_way_id') not in (None, '')
            else 'r' + str(properties['osm_id'])
            if properties.get('osm_id') not in (None, '')
            else ''
        )
        source_geometry_key = osm_key or str(id) or f"feature-{feature_index}"
        for geom_index, geom in enumerate(geoms):
            if not geom.is_valid or geom.is_empty:
                _record_geometry_drop(geometry_diagnostics, "invalid_simple_geometry")
                continue
            if (label_diagnostics is not None and label_tags and
                    feature['geometry']['type'] in ('LineString', 'MultiLineString')):
                label_diagnostics['namedRoadsPreserved'] = \
                    label_diagnostics.get('namedRoadsPreserved', 0) + 1
            extracted.append({
                'id': id, # for testing/debugging
                'type': feature_type,
                'geom_type': 'line' if feature['geometry']['type'] in ('LineString','MultiLineString') else 'polygon',
                'tags':  feature_type_tags,
                'label_tags': label_tags,
                'label_join': label_join,
                'building_tags': building_tags,
                'osm_key': osm_key,
                '_source_geometry_key': source_geometry_key,
                '_source_geometry_component': geom_index,
                'z_order': z_order,
                'geom': geom
                })
        done += 1
        print("  Step 3/5 Extract. {:.0%}  ".format(done/total), end='\r')
    
    # print report
    feat_found = set()
    for ext in extracted:
        feat_found.add( ext["type"])
    print("Feature types extracted:")
    for ft in sorted(feat_found):
        print(ft)
    return extracted


def style_features( features, styles):
    """Apply styles (color,width) to the features based in the definitions in styles
    """
    styled_features = []
    for feat in features:
        feature_type = feat['type']
        feature_type_group = feat['type'].split('.')[0]
        feature_color = '0xF972' # default pink
        feature_width = None   # default
        feature_maxzoom = ''   # default
        found = False
        conf_styles = styles['lines'] if feat['geom_type'] == 'line' else styles['polygons']
        for style_item in conf_styles:
            if feature_type in style_item['features'] or feature_type_group in style_item['features']:
                if 'color' in style_item: feature_color = styles["colors"][ style_item['color']]
                if 'width' in style_item: feature_width = style_item['width']
                if 'maxzoom' in style_item: feature_maxzoom = style_item['maxzoom']
                found = True
                break # keep first match
        if not found: 
            print("Not mapped: ", feature_type, feature_type_group)
        styled = dict(feat)
        styled.update({
            'type': feature_type,
            'color': feature_color,
            'width': feature_width,
            'maxzoom': feature_maxzoom,
        })
        styled_features.append(styled)
    return styled_features


def clip_lines( features, bbox: Polygon, label_diagnostics=None): #TODO remove feats that are fully contained, return remaining
    """ Clip lines to the box area. Each line can be splitted into one or several lines.
        Returns a list of LineStrings
    """
    clipped = []
    for feat in features:
        line = feat['geom']
        assert type( line) == LineString, type(line)
        if not bbox.intersects( line) or bbox.touches( line): continue
        parts = intersection( line, bbox)
        assert type( parts) in (LineString, MultiLineString), type( parts)
        if not parts.is_valid: continue
        for p in parts.geoms if type(parts) == MultiLineString else [parts,]:
            assert type( p) == LineString, type( p)
            if p.is_valid:
                new_feat = dict( feat)
                new_feat['geom'] = p
                new_feat['bbox'] = p.bounds
                candidates = []
                for candidate in feat.get('label_candidates', []):
                    midpoint = Point(candidate['midpoint'])
                    if bbox.covers(midpoint) and p.distance(midpoint) <= 1.5:
                        candidates.append(candidate)
                new_feat['label_candidates'] = candidates
                if label_diagnostics is not None and new_feat.get('label_tags'):
                    label_diagnostics['namedRoadsClipped'] = \
                        label_diagnostics.get('namedRoadsClipped', 0) + 1
                    label_diagnostics['clippedCandidates'] = \
                        label_diagnostics.get('clippedCandidates', 0) + len(candidates)
                    dropped = len(feat.get('label_candidates', [])) - len(candidates)
                    label_diagnostics['candidatesRejectedByBlockOwnership'] = \
                        label_diagnostics.get('candidatesRejectedByBlockOwnership', 0) + max(0, dropped)
                clipped.append( new_feat)            
    return clipped 

def _polygonal_parts(value):
    if isinstance(value, Polygon):
        return [] if value.is_empty else [value]
    if isinstance(value, (MultiPolygon, GeometryCollection)):
        parts = []
        for child in value.geoms:
            parts.extend(_polygonal_parts(child))
        return parts
    return []


def _equivalence_tolerance(polygon):
    return max(
        _GEOMETRY_EQUIVALENCE_ABSOLUTE_TOLERANCE,
        polygon.area * _GEOMETRY_EQUIVALENCE_RELATIVE_TOLERANCE,
    )


def _decompose_hole_free(polygon, remaining_piece_budget):
    if not polygon.interiors:
        return [_canonicalize_shapely_polygon(polygon)]

    pieces = []
    for candidate in triangulate(polygon):
        for part in _polygonal_parts(intersection(candidate, polygon)):
            if part.is_empty or part.area <= 0:
                continue
            if part.interiors:
                raise GenericGeometryError(
                    "bounded polygon decomposition retained an interior ring"
                )
            pieces.append(_canonicalize_shapely_polygon(part))
            if len(pieces) > remaining_piece_budget:
                raise GenericGeometryLimitError(
                    "generic polygon decomposition exceeded its piece budget"
                )

    if not pieces:
        raise GenericGeometryError("generic polygon decomposition produced no area")
    pieces.sort(key=_polygon_sort_key)
    merged = unary_union(pieces)
    tolerance = _equivalence_tolerance(polygon)
    if polygon.symmetric_difference(merged).area > tolerance:
        raise GenericGeometryError("generic polygon decomposition changed covered area")
    if sum(piece.area for piece in pieces) - merged.area > tolerance:
        raise GenericGeometryError("generic polygon decomposition produced overlapping pieces")
    for interior in polygon.interiors:
        hole = Polygon(interior)
        if merged.intersection(hole).area > tolerance:
            raise GenericGeometryError("generic polygon decomposition covered an interior ring")
    return pieces


def _quantized_polygon(polygon, min_x, min_y):
    def quantize_ring(ring):
        return [
            (int(round(x - min_x)), int(round(y - min_y)))
            for x, y in ring.coords
        ]

    value = Polygon(
        quantize_ring(polygon.exterior),
        [quantize_ring(interior) for interior in polygon.interiors],
    )
    if value.is_empty or not value.is_valid or value.area <= 0:
        raise GenericGeometryError(
            "generic polygon becomes invalid at FMB coordinate precision"
        )
    return value


def _validate_quantized_decomposition(source, pieces, min_x, min_y):
    quantized_source = _quantized_polygon(source, min_x, min_y)
    quantized_pieces = [_quantized_polygon(piece, min_x, min_y) for piece in pieces]
    merged = unary_union(quantized_pieces)
    tolerance = _equivalence_tolerance(quantized_source)
    if quantized_source.symmetric_difference(merged).area > tolerance:
        raise GenericGeometryError(
            "generic polygon decomposition changes area at FMB coordinate precision"
        )
    if sum(piece.area for piece in quantized_pieces) - merged.area > tolerance:
        raise GenericGeometryError(
            "generic polygon decomposition overlaps at FMB coordinate precision"
        )


def clip_polygons(
    features,
    bbox: Polygon,
    *,
    max_pieces_per_source=MAX_GENERIC_POLYGON_PIECES_PER_SOURCE,
    max_pieces_per_block=MAX_GENERIC_POLYGON_PIECES_PER_BLOCK,
):
    """ Clip polygons to the bbox area. Each polygon can be splitted into one or several polygons.
        Returns a list of polygons
    """
    clipped = []
    source_piece_counts = {}
    min_x, min_y = bbox.bounds[:2]
    for feat in features:
        polygon = feat['geom']
        if not isinstance(polygon, Polygon):
            raise GenericGeometryError("generic polygon feature is not a Polygon")
        if not bbox.intersects( polygon) or bbox.touches( polygon): continue
        parts = intersection( polygon, bbox)
        if not parts.is_valid:
            raise GenericGeometryError("clipping produced invalid generic geometry")
        source_key = feat.get('_source_geometry_key', str(feat.get('id', '')))
        polygonal_parts = [
            _canonicalize_shapely_polygon(part)
            for part in _polygonal_parts(parts)
        ]
        for part in sorted(polygonal_parts, key=_polygon_sort_key):
            if part.is_valid and not part.is_empty:
                source_count = source_piece_counts.get(source_key, 0)
                remaining_source = max_pieces_per_source - source_count
                remaining_block = max_pieces_per_block - len(clipped)
                if remaining_source <= 0 or remaining_block <= 0:
                    raise GenericGeometryLimitError(
                        "generic polygon decomposition exceeded its piece budget"
                    )
                pieces = _decompose_hole_free(
                    part, min(remaining_source, remaining_block)
                )
                _validate_quantized_decomposition(part, pieces, min_x, min_y)
                source_piece_counts[source_key] = source_count + len(pieces)
                if source_piece_counts[source_key] > max_pieces_per_source:
                    raise GenericGeometryLimitError(
                        "generic polygon decomposition exceeded the per-source limit"
                    )
                if len(clipped) + len(pieces) > max_pieces_per_block:
                    raise GenericGeometryLimitError(
                        "generic polygon decomposition exceeded the per-block limit"
                    )
                for p in pieces:
                    if p.interiors:
                        raise GenericGeometryError(
                            "generic polygon output retained an interior ring"
                        )
                    new_feat = dict(feat)
                    new_feat['geom'] = p
                    new_feat['bbox'] = p.bounds
                    clipped.append(new_feat)
        # if len( new_feat['geom'].coords) <= 2: continue
    return clipped


def color_to_24bits( color565):
    """ Convert color codification. 
        Some displays use RGB565 schema: 5 bits, 6 bits, 5 bits.
    """
    color565 = int( color565, 16) # convert from hex string
    r = (color565 >> 8) & 0xF8
    r |= (r >> 5)
    g = (color565 >> 3) & 0xFC
    g |= (g >> 6)
    b = (color565 << 3) & 0xF8
    b |= (b >> 5)
    return (b << 16) | (g << 8) | r  # for some reason it expects the channels in reverse order (bgr)


def draw_feature(image, draw: ImageDraw, feat, min_x, min_y, image_size):
    image_width, image_height = image_size
    coords = feat['geom'].exterior.coords if type( feat['geom']) == Polygon else feat['geom'].coords
    points = [ (( x-min_x), image_height-(y-min_y) ) for x,y in coords]
    color = color_to_24bits( feat['color'])    
    if feat['geom_type'] == 'polygon':
        left = max(0, math.floor(min(point[0] for point in points)) - 1)
        top = max(0, math.floor(min(point[1] for point in points)) - 1)
        right = min(image_width, math.ceil(max(point[0] for point in points)) + 2)
        bottom = min(image_height, math.ceil(max(point[1] for point in points)) + 2)
        if right <= left or bottom <= top:
            return
        mask = Image.new("L", (right - left, bottom - top), color=0)
        mask_draw = ImageDraw.Draw(mask)

        def local_points(ring):
            return [
                (x - min_x - left, image_height - (y - min_y) - top)
                for x, y in ring.coords
            ]

        mask_draw.polygon(local_points(feat['geom'].exterior), fill=255)
        for interior in feat['geom'].interiors:
            mask_draw.polygon(local_points(interior), fill=0)
        image.paste(color, (left, top, right, bottom), mask)
    else:
        width = max( round( feat['width']), 1) if feat['width'] else 1
        draw.line( points, fill = color, width = width)


def render_map(
    features,
    file_name,
    min_x,
    min_y,
    image_size=(IMG_WIDTH, IMG_HEIGHT),
):
    """Export an image of the features
    """
    image = Image.new("RGB", image_size, color=BACKGROUND_COLOR)
    draw = ImageDraw.Draw(image)
    for feat in features:
        draw_feature(
            image,
            draw,
            feat,
            min_x=min_x,
            min_y=min_y,
            image_size=image_size,
        )
    image.save( file_name)

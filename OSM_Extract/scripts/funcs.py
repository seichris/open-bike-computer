from shapely import geometry, LineString, LinearRing, Polygon, MultiPolygon, MultiLineString, Point, intersection
from shapely.ops import triangulate
import PIL.ImageDraw as ImageDraw
import PIL.Image as Image
import math

IMG_WIDTH, IMG_HEIGHT = pow( 2, 12), pow( 2, 12) # 4096 x 4096
BACKGROUND_COLOR = 0xDDDDDD

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


def get_geoms( osm_geom ):
    """ Converts the geometry or multigeometry to a list of simple geometries (LineString, Polygon)
    """
    geoms = []
    geom_type = osm_geom['type']
    if geom_type == 'LineString':
        geoms.append( LineString( osm_geom['coordinates']))
    elif geom_type == 'Polygon':
        geoms.append( Polygon( osm_geom['coordinates']))
    elif geom_type == 'MultiLineString':
        for g in osm_geom['coordinates']:
            geoms.append( LineString( g))
    elif geom_type == 'MultiPolygon':
        # print("g", osm_geoms)
        geoms.append( Polygon( osm_geom['coordinates'][0][0])) # we take just the 1st, the rest are holes #TODO: manage holes
    else: print("ERROR. Unknow osm geom type:", geom_type)
    # elif geom_type == 'GeometryCollection': # TODO
    #     return []    
    # else: print("ERROR: unknow geometry type:", geom_type)
    return geoms

def process_features( features, conf ):
    """ Extract the features based in the definitions in conf: which features to extract and which tags
    """
    extracted = []
    total = len(features)
    done = 0
    for feature in features:
        properties = feature['properties']
        if 'other_tags' in feature['properties']:
            tags = parse_tags( feature['properties']['other_tags'] )  
        else: tags = dict()
        
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
        geoms = get_geoms( feature['geometry']) 
        id = properties['osm_way_id'] if 'osm_way_id' in properties else \
            properties['osm_id'] if 'osm_id' in properties else ''
        for geom in geoms:
            if not geom.is_valid or geom.is_empty: continue
            extracted.append({
                'id': id, # for testing/debugging
                'type': feature_type,
                'geom_type': 'line' if feature['geometry']['type'] in ('LineString','MultiLineString') else 'polygon',
                'tags':  feature_type_tags,
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
        styled_features.append({
            'id': feat['id'],  # for debugging
            'type': feature_type, # remove
            'geom_type': feat['geom_type'],
            'color': feature_color, 
            'width': feature_width,
            'maxzoom': feature_maxzoom,
            'z_order': feat['z_order'],
            'geom': feat['geom'],
            })
    return styled_features


def clip_lines( features, bbox: Polygon): #TODO remove feats that are fully contained, return remaining
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
                clipped.append( new_feat)            
    return clipped 

def clip_polygons( features, bbox: Polygon):
    """ Clip polygons to the bbox area. Each polygon can be splitted into one or several polygons.
        Returns a list of polygons
    """
    clipped = []
    for feat in features:
        polygon = feat['geom']
        assert type( polygon) == Polygon, type( polygon)
        if not bbox.intersects( polygon) or bbox.touches( polygon): continue
        parts = intersection( polygon, bbox)
        assert type( parts) in (Polygon, MultiPolygon), type( parts)
        if not parts.is_valid: continue
        for p in parts.geoms if type(parts) == MultiPolygon else [parts,]:
            if p.is_valid and not p.is_empty:
                new_feat = dict( feat)
                new_feat['geom'] = p
                new_feat['bbox'] = p.bounds
                clipped.append( new_feat)
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


def draw_feature( draw: ImageDraw, feat, min_x, min_y ):
    coords = feat['geom'].exterior.coords if type( feat['geom']) == Polygon else feat['geom'].coords
    points = [ (( x-min_x), IMG_HEIGHT-(y-min_y) ) for x,y in coords]
    color = color_to_24bits( feat['color'])    
    if feat['geom_type'] == 'polygon':
        draw.polygon( points, fill = color)
    else:
        width = max( round( feat['width']), 1) if feat['width'] else 1
        draw.line( points, fill = color, width = width)


def render_map( features, file_name, min_x, min_y):
    """Export an image of the features
    """
    image = Image.new("RGB", (IMG_WIDTH, IMG_HEIGHT), color=BACKGROUND_COLOR)
    draw = ImageDraw.Draw(image)
    for feat in features:
        draw_feature( draw, feat, min_x=min_x, min_y=min_y)
    image.save( file_name)

export interface Env extends Omit<CatalogBindings, "RETENTION_GRACE_DAYS"> {
  RETENTION_GRACE_DAYS?: string;
  R2_DEVELOPMENT_ACCESS_KEY_ID: string;
  R2_DEVELOPMENT_SECRET_ACCESS_KEY: string;
  R2_PRODUCTION_ACCESS_KEY_ID: string;
  R2_PRODUCTION_SECRET_ACCESS_KEY: string;
  SERVICE_KEYS_JSON: string;
}

export type Channel = "development" | "production";
export type BucketSlot = Channel;

export interface LibraryPrincipal {
  id: string;
}

export interface MapEntryRow {
  id: string;
  legacy_map_id: string;
  content_receipt: string;
  origin_channel: Channel;
  canonical_name: string;
  source_region_name: string | null;
  bounds_json: string | null;
  renderer: string;
  renderer_format_version: number;
  features_json: string;
  attribution_json: string;
  generated_at: string | null;
  delivery_state: string;
  created_at: string;
  updated_at: string;
}

export interface ArtifactRow {
  id: string;
  map_entry_id: string;
  bucket_slot: BucketSlot;
  object_key: string;
  format: string;
  media_type: string;
  filename: string;
  byte_count: number;
  sha256: string;
  manifest_receipt: string | null;
  signed_manifest_receipt: string | null;
  signature_key_id: string | null;
  signature_key_sha256: string | null;
  producer_build_sha256: string | null;
  producer_image_digest: string | null;
  reader_requirements_json: string | null;
  generation_class: string;
  superseded_at: string | null;
  generation_head: number;
  required_ios_build: string | null;
  required_ios_git_sha: string | null;
  required_ios_build_sha256: string | null;
  required_firmware_version: string | null;
  required_firmware_build: number | null;
  required_firmware_git_sha: string | null;
  delivery_tier: Channel;
  state: string;
  created_at: string;
  verified_at: string;
}

export interface CatalogPrincipal { subject: string; displayName: string }
export interface CharacterPack {
  format: string; id: string; version: number; name: string; description: string; creator: string;
  identity: { backstory: string; voice: string };
  personality: { traits: string[]; instructions: string[] };
  appearance: { renderer: 'native-doboo' | 'spritesheet'; tint: string;
    sprite?: { layout: 'pets-v1' | 'pets-v2'; mimeType: string; base64: string } };
}
export interface CatalogRef { id: string; version?: number; creatorId?: string }
export interface CatalogSummary {
  id: string; version: number; name: string; description: string;
  /** Verified catalog owner; character.creator is only the author's display text. */
  creatorId: string; creatorName: string; packCreator: string;
  traits: string[]; appearance: { renderer: string; tint: string; layout?: string };
  digest: string; publishedAt: string;
}
export interface CatalogDownload { character: CharacterPack; summary: CatalogSummary }
export interface CatalogImportInput { id: string; version: number; creatorId: string; digest: string }
export interface CatalogImportReceipt extends CatalogImportInput {
  receiptId: string; importerId: string; importedAt: string;
  /** The client reports this only after local validation/persistence. The server cannot prove a device import. */
  confirmation: 'client-reported';
}
export interface CatalogSearch { query?: string; creatorId?: string; excludeOwn?: boolean; limit?: number; offset?: number }

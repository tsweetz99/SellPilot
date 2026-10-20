// What the AI is asked to do. These live on the server so that callers can send only photos or a description, never their own
// instructions: the service cannot be used as a general-purpose Claude proxy.
// The app has its own copy for the "bring your own key" path. Keep the lists below in step with the app (SellItem.categories
// and ItemCondition); a test in the app's test suite fails if they drift apart.

export const CATEGORIES = ["Books", "Tools", "Furniture", "Electronics", "Sporting goods", "Camping equipment", "Collectibles", "Household items", "Baby gear", "Décor", "Automotive accessories", "Hobby equipment", "Other"];
export const CONDITIONS = ["New", "Excellent", "Good", "Fair", "For parts"];
export const FACT_NAMES = ["brand", "model", "product_type", "color", "material", "size", "voltage", "power_source", "battery_included", "capacity", "quantity", "year", "country_of_origin", "style", "pattern", "features"];

export const IDENTIFY_TOOL = "report_identification";
export const FACTS_TOOL = "report_facts";

export const IDENTIFY_SYSTEM = `You identify second-hand items for a seller's marketplace listing, using only the seller's photos. \
Report only what the photos support. Read labels, rating plates and model stickers when legible and list the text you actually read in visible_text. \
Never invent a model number: if none is legible and you are not certain, leave model_number null. \
Use the brand "Unknown" when no brand is visible or recognizable. \
confidence is your honest probability (0 to 1) that the title, brand and model are correct for this exact item; stay below 0.6 when guessing from shape alone. \
Describe visible wear, damage and missing parts in condition_notes; never hide defects. \
Give up to 3 alternates only when there is real doubt. \
If the photos show more than one item, identify the most prominent one and mention the others in condition_notes. \
You must answer by calling the report_identification tool; do not reply with plain text.`;

export const FACTS_SYSTEM = `You extract facts about a second-hand item from the seller's own description. Return a fact only if the description clearly supports it; \
leave everything else out. Never guess. For battery_included answer yes or no (a model ending in B or the words "tool only" mean no). \
Use "other" for any further facts that are clearly stated. Answer by calling the report_facts tool.`;

const match = {
  type: "object",
  properties: { title: { type: "string" }, brand: { type: "string" }, model: { type: "string" }, category: { type: "string", enum: CATEGORIES } },
  required: ["title", "brand", "model", "category"],
};

export const IDENTIFY_SCHEMA = {
  type: "object",
  properties: {
    title: { type: "string", description: "Marketplace-ready product name, e.g. brand + product + key spec." },
    brand: { type: "string" },
    model: { type: "string", description: "Model name or number; empty string if unknown." },
    model_number: { type: ["string", "null"], description: "Only a model/part number you can read or are certain of." },
    category: { type: "string", enum: CATEGORIES },
    subcategory: { type: "string" },
    color: { type: "string" },
    condition: { type: "string", enum: CONDITIONS },
    condition_notes: { type: "string" },
    confidence: { type: "number", minimum: 0, maximum: 1 },
    visible_text: { type: "array", items: { type: "string" }, description: "Text read from labels, plates and packaging." },
    attributes: { type: "object", additionalProperties: { type: "string" }, description: "Other useful facts, e.g. voltage, size, material." },
    alternates: { type: "array", items: match, maxItems: 3 },
  },
  required: ["title", "brand", "model", "category", "subcategory", "color", "condition", "confidence"],
};

export const FACTS_SCHEMA = {
  type: "object",
  properties: {
    ...Object.fromEntries(FACT_NAMES.map((name) => [name, { type: "string" }])),
    other: { type: "object", additionalProperties: { type: "string" }, description: "Other clearly stated facts, keyed by a short name." },
  },
};

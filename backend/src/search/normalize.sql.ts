/**
 * Arabic + English search normalisation, as PostgreSQL SQL.
 *
 * Lives in the database rather than in application code so that the stored
 * form and the query form are produced by the same function. Normalising on
 * write in TypeScript and again on read is how the two drift, and the symptom
 * is a search that quietly stops matching some items.
 *
 * IMMUTABLE is required: a generated column cannot use a volatile function.
 *
 * **Versioned on purpose.** PostgreSQL 16 has no `ALTER COLUMN … SET
 * EXPRESSION`, so changing the folding rules means dropping and re-adding the
 * generated column. A versioned name makes that migration explicit instead of
 * silently redefining what existing rows were normalised with.
 *
 * What it does, in order:
 *   1. lowercase — affects Latin only; Arabic has no case
 *   2. strip harakat ً ٌ ٍ َ ُ ِ ّ ْ and the superscript alef ٰ
 *   3. strip tatweel ـ, the decorative letter-stretching character
 *   4. fold Arabic-Indic digits ٠١٢٣٤٥٦٧٨٩ to 0-9, since the app renders
 *      Arabic-Indic numerals but batch numbers and sizes are typed either way
 *   5. fold letter variants:  أ إ آ ٱ → ا    ى → ي    ة → ه    ؤ → و    ئ → ي
 *   6. collapse runs of whitespace and trim
 *
 * Folding ة → ه and ى → ي is deliberate: clinics type both forms
 * interchangeably, so «سرنجة» and «سرنجه» must reach the same item.
 */
export const NORMALIZE_FN_NAME = 'search_normalize_v1';

export const NORMALIZE_SQL = `
CREATE OR REPLACE FUNCTION ${NORMALIZE_FN_NAME}(input text)
RETURNS text
LANGUAGE sql
IMMUTABLE
STRICT
PARALLEL SAFE
AS $func$
  SELECT btrim(
    regexp_replace(
      translate(
        regexp_replace(lower(input), '[ًٌٍَُِّْٰـ]', '', 'g'),
        'أإآٱىةؤئ٠١٢٣٤٥٦٧٨٩',
        'اااايهوي0123456789'
      ),
      '\\s+', ' ', 'g'
    )
  )
$func$;
`;

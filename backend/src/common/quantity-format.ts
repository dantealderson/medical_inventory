/**
 * A quantity in words, for notification text composed on the server: boxes
 * plus loose units, as the apps show it (ui_kit formatQuantity). 230 units
 * at 100 per box reads "2 علبة + 30 سرنجة". Digits stay Western (D14).
 */
export function formatQuantityAr(units: number, unitsPerBox: number, unitLabelAr: string): string {
  const boxLabel = 'علبة';
  if (units === 0) return `0 ${boxLabel}`;
  const boxes = Math.floor(units / unitsPerBox);
  const remainder = units % unitsPerBox;
  if (remainder === 0) return `${boxes} ${boxLabel}`;
  if (boxes === 0) return `${remainder} ${unitLabelAr}`;
  return `${boxes} ${boxLabel} + ${remainder} ${unitLabelAr}`;
}

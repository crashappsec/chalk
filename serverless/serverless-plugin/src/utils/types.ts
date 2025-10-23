export type NonNullableObject<T extends object> = {
  [K in keyof T]: NonNullable<T[K]>;
};

export function nonNullable<T extends object>(obj: T) {
  return Object.fromEntries(
    Object.entries(obj).filter((kv) => kv[1] !== undefined && kv[1] !== null),
  ) as Partial<NonNullableObject<T>>;
}

export function connect(): never {
  throw new Error("TCP sockets are not available in unit tests");
}

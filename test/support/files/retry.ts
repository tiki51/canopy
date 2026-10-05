// Retries a flaky call with exponential backoff.
export async function retry<T>(fn: () => Promise<T>, attempts = 3): Promise<T> {
  let delay = 100;
  for (let i = 1; ; i++) {
    try {
      return await fn();
    } catch (error) {
      if (i >= attempts) throw error;
      await new Promise((resolve) => setTimeout(resolve, delay));
      delay *= 2;
    }
  }
}

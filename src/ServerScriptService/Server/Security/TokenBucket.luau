--!strict
--[=[
	TokenBucket
	Limitador de tasa predecible por jugador mediante algoritmo Token Bucket.
	- Mantiene buckets independientes de lectura (GetBlueprint) y escritura (PlacePiece/RemovePiece).
	- Aísla completamente a cada UserId.
	- Permite inyección opcional de reloj para pruebas deterministas y limpia memoria al desconectarse.
]=]

export type BucketKind = "Write" | "Read"

type BucketState = {
	Tokens: number,
	LastRefill: number,
}

type PlayerBuckets = {
	Write: BucketState,
	Read: BucketState,
}

export type LimiterOptions = {
	WriteCapacity: number,
	WriteRefillPerSecond: number,
	ReadCapacity: number,
	ReadRefillPerSecond: number,
	Clock: (() -> number)?,
}

export type TokenBucketLimiter = {
	Consume: (self: TokenBucketLimiter, userId: number, kind: BucketKind, cost: number?) -> (boolean, number),
	ClearPlayer: (self: TokenBucketLimiter, userId: number) -> (),
	GetTrackedPlayerCount: (self: TokenBucketLimiter) -> number,
	ResetAll: (self: TokenBucketLimiter) -> (),
}

local TokenBucket = {}

function TokenBucket.Create(options: LimiterOptions): TokenBucketLimiter
	local clock: () -> number = options.Clock or os.clock
	local bucketsByUserId: { [number]: PlayerBuckets } = {}

	local limiter = {} :: TokenBucketLimiter

	local function getOrCreatePlayerBuckets(userId: number, now: number): PlayerBuckets
		local existing = bucketsByUserId[userId]
		if existing then
			return existing
		end
		local created: PlayerBuckets = {
			Write = {
				Tokens = options.WriteCapacity,
				LastRefill = now,
			},
			Read = {
				Tokens = options.ReadCapacity,
				LastRefill = now,
			},
		}
		bucketsByUserId[userId] = created
		return created
	end

	function limiter:Consume(userId: number, kind: BucketKind, cost: number?): (boolean, number)
		local amount = cost or 1
		local now = clock()
		local playerBuckets = getOrCreatePlayerBuckets(userId, now)

		local state: BucketState
		local capacity: number
		local refillRate: number

		if kind == "Read" then
			state = playerBuckets.Read
			capacity = options.ReadCapacity
			refillRate = options.ReadRefillPerSecond
		else
			state = playerBuckets.Write
			capacity = options.WriteCapacity
			refillRate = options.WriteRefillPerSecond
		end

		local elapsed = math.max(0, now - state.LastRefill)
		if elapsed > 0 then
			state.Tokens = math.min(capacity, state.Tokens + elapsed * refillRate)
			state.LastRefill = now
		end

		if state.Tokens + 1e-6 >= amount then
			state.Tokens = math.max(0, state.Tokens - amount)
			return true, state.Tokens
		end

		return false, state.Tokens
	end

	function limiter:ClearPlayer(userId: number)
		bucketsByUserId[userId] = nil
	end

	function limiter:GetTrackedPlayerCount(): number
		local count = 0
		for _ in pairs(bucketsByUserId) do
			count += 1
		end
		return count
	end

	function limiter:ResetAll()
		table.clear(bucketsByUserId)
	end

	return limiter
end

return TokenBucket


package impl.di

interface Repo

class RepoImpl : Repo

class CachedRepo(private val inner: Repo) : Repo

interface Clock

object SystemClock

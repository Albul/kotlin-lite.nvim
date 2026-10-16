package impl.di

val appModule = module {
    single<Repo> { RepoImpl() }
    factory<Repo>(named("cached")) { CachedRepo(get()) }
    single { RepoImpl() } bind Repo::class
    singleOf(::RepoImpl) { bind<Repo>() }
    single<Clock> { SystemClock }
    single<RepoImpl> { RepoImpl() }
}

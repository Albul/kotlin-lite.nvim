package impl.elsewhere

interface Repo

val otherModule = module {
    single<Repo> { object : Repo {} }
}

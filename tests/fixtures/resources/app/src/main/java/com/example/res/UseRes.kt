package com.example.res

import android.content.Context
import com.example.shared.generated.resources.Res

fun texts(ctx: Context) {
    ctx.getString(R.string.greeting)
    ctx.getString(com.example.res.R.string.app_name)
    val apples = R.plurals.apples
    val planets = R.array.planets
    val theme = R.style.Theme_Fixture
    val accent = R.color.accent
    val star = R.drawable.ic_star
    val launcher = R.mipmap.ic_launcher
    val layout = R.layout.screen_main
    val title = R.id.title
    val missing = R.string.absent
    val sdk = android.R.string.ok
    val maracas = Res.string.maracas
    val logo = Res.drawable.logo
}
